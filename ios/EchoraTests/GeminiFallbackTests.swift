import XCTest
import simd
@testable import Echora

/// Fake network: answers per model name after an optional delay, records which models were asked.
private final class StubURLProtocol: URLProtocol {
    enum Reply {
        case http(Int, String, delay: TimeInterval)
        case timeout(after: TimeInterval)
    }

    private static let lock = NSLock()
    private static var _replies: [String: Reply] = [:]
    private static var _requestedModels: [String] = []

    static var replies: [String: Reply] {
        get { lock.lock(); defer { lock.unlock() }; return _replies }
        set { lock.lock(); _replies = newValue; lock.unlock() }
    }

    static var requestedModels: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedModels
    }

    static func reset() {
        lock.lock()
        _replies = [:]
        _requestedModels = []
        lock.unlock()
    }

    private static func record(_ model: String) {
        lock.lock()
        _requestedModels.append(model)
        lock.unlock()
    }

    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let replies = Self.replies
        let model = replies.keys.first { path.contains("/\($0):") } ?? "unknown"
        Self.record(model)

        guard let reply = replies[model], let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch reply {
        case .timeout(let after):
            deliver(after: after) { protocolSelf in
                protocolSelf.client?.urlProtocol(protocolSelf, didFailWithError: URLError(.timedOut))
            }
        case .http(let status, let body, let delay):
            deliver(after: delay) { protocolSelf in
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
                if let response {
                    protocolSelf.client?.urlProtocol(protocolSelf, didReceive: response, cacheStoragePolicy: .notAllowed)
                }
                protocolSelf.client?.urlProtocol(protocolSelf, didLoad: Data(body.utf8))
                protocolSelf.client?.urlProtocolDidFinishLoading(protocolSelf)
            }
        }
    }

    private func deliver(after delay: TimeInterval, _ action: @escaping (StubURLProtocol) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else {
                return
            }
            action(self)
        }
    }

    override func stopLoading() {
        stopped = true
    }
}

final class GeminiFallbackTests: XCTestCase {
    private let primary = "model-a"
    private let backup = "model-b"

    private let foundBody = #"{"candidates":[{"content":{"parts":[{"text":"{\"found\":true,\"label\":\"mug\",\"box_2d\":[100,200,300,400]}"}]}}]}"#
    private let backupFoundBody = #"{"candidates":[{"content":{"parts":[{"text":"{\"found\":true,\"label\":\"cup\",\"box_2d\":[100,200,300,400]}"}]}}]}"#
    private let notFoundBody = #"{"candidates":[{"content":{"parts":[{"text":"{\"found\":false,\"label\":\"mug\",\"box_2d\":[],\"reason\":\"not visible\"}"}]}}]}"#

    /// Scaled-down timings: race after 0.3 s, give up after 1.5 s.
    private func makeLocator() -> GeminiLocator {
        GeminiLocator(
            apiKey: "test-key",
            models: [primary, backup],
            hedgeDelay: 0.3,
            budget: 1.5,
            protocolClasses: [StubURLProtocol.self]
        )
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: Data([0xFF, 0xD8]),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3,
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: .portrait,
            depth: nil
        )
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func testFastPrimaryIsTheOnlyCall() async throws {
        StubURLProtocol.replies = [
            primary: .http(200, foundBody, delay: 0.05),
            backup: .http(200, backupFoundBody, delay: 0.05)
        ]

        let detection = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())

        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary])
    }

    func testSlowPrimaryLosesTheRace() async throws {
        StubURLProtocol.replies = [
            primary: .http(200, foundBody, delay: 1.2),
            backup: .http(200, backupFoundBody, delay: 0.1)
        ]
        let started = Date()

        let detection = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())

        XCTAssertEqual(detection.label, "cup")   // backup answered first
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary, backup])
    }

    func testOverloadedPrimaryStartsBackupImmediately() async throws {
        StubURLProtocol.replies = [
            primary: .http(503, "{}", delay: 0.02),
            backup: .http(200, backupFoundBody, delay: 0.05)
        ]
        let started = Date()

        let detection = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())

        XCTAssertEqual(detection.label, "cup")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)   // didn't wait for the 0.3 s race timer
    }

    func testRateLimitedPrimaryFallsBack() async throws {
        StubURLProtocol.replies = [
            primary: .http(429, "{}", delay: 0.02),
            backup: .http(200, backupFoundBody, delay: 0.05)
        ]

        let detection = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())

        XCTAssertEqual(detection.label, "cup")
    }

    func testNotFoundEndsTheRace() async {
        StubURLProtocol.replies = [
            primary: .http(200, notFoundBody, delay: 0.05),
            backup: .http(200, backupFoundBody, delay: 0.05)
        ]

        do {
            _ = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())
            XCTFail("expected objectNotFound")
        } catch {
            XCTAssertEqual(error as? EchoraError, .objectNotFound("not visible"))
        }
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary])
    }

    func testBadRequestEndsTheRace() async {
        StubURLProtocol.replies = [
            primary: .http(400, #"{"error":{"message":"bad"}}"#, delay: 0.02),
            backup: .http(200, backupFoundBody, delay: 0.05)
        ]

        do {
            _ = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())
            XCTFail("expected locatorFailed")
        } catch {
            XCTAssertEqual(error as? EchoraError, .locatorFailed("HTTP 400: bad"))
        }
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary])
    }

    func testBothSlowReportsTimeout() async {
        StubURLProtocol.replies = [
            primary: .timeout(after: 0.6),
            backup: .timeout(after: 0.6)
        ]

        do {
            _ = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())
            XCTFail("expected locatorTimeout")
        } catch {
            XCTAssertEqual(error as? EchoraError, .locatorTimeout)
        }
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary, backup])
    }
}
