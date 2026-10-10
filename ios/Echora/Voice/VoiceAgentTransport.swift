import Foundation
import os

/// The conversation socket, behind a protocol so the listener is unit tested without a network.
/// Callbacks arrive on the main queue. Call every method from the main thread.
protocol VoiceAgentTransport: AnyObject {
    var onText: ((String) -> Void)? { get set }
    /// The socket closed or failed without `close()` being called. The string is a reason for logs.
    var onClose: ((String) -> Void)? { get set }

    func connect(to url: URL)
    /// Messages sent before the handshake finishes are queued by the socket.
    func send(_ text: String)
    func close()
}

final class WebSocketVoiceAgentTransport: VoiceAgentTransport {
    var onText: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let logger = Logger(subsystem: "com.gwh.echora", category: "VoiceAgentSocket")

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
    }

    func connect(to url: URL) {
        close()
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        receiveNext(on: newTask)
    }

    func send(_ text: String) {
        guard let task else {
            return
        }
        task.send(.string(text)) { [weak self] error in
            guard let error else {
                return
            }
            DispatchQueue.main.async {
                self?.handleFailure(of: task, reason: "send failed: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        guard let task else {
            return
        }
        self.task = nil
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                self?.handleReceive(result, on: task)
            }
        }
    }

    private func handleReceive(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        on task: URLSessionWebSocketTask
    ) {
        // A socket we already closed or replaced: ignore whatever it still delivers.
        guard task === self.task else {
            return
        }

        switch result {
        case .failure(let error):
            handleFailure(of: task, reason: error.localizedDescription)
        case .success(let message):
            switch message {
            case .string(let text):
                onText?(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    onText?(text)
                }
            @unknown default:
                break
            }
            receiveNext(on: task)
        }
    }

    private func handleFailure(of task: URLSessionWebSocketTask, reason: String) {
        guard task === self.task else {
            return
        }
        logger.error("Socket closed: \(reason, privacy: .public)")
        self.task = nil
        task.cancel(with: .goingAway, reason: nil)
        onClose?(reason)
    }
}
