import AVFoundation
import os

/// Speaks a short phrase. Behind a protocol so the announcements are unit tested without audio.
protocol SpokenAnnouncing: AnyObject {
    /// Returns when the phrase has been spoken, or was cut off.
    func speak(_ text: String) async
}

/// On-device text to speech (`AVSpeechSynthesizer`): no network, no key, starts at once.
/// It plays through the app's audio session and never configures it (the Audio module owns that).
@MainActor
final class SpeechAnnouncer: NSObject, SpokenAnnouncing, AVSpeechSynthesizerDelegate {
    /// Gives up waiting for the synthesizer after this, so a request can never hang on speech.
    private static let maximumSeconds: TimeInterval = 5

    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.gwh.echora", category: "Announcer")
    private var currentUtterance: ObjectIdentifier?
    private var pending: CheckedContinuation<Void, Never>?
    private var watchdog: DispatchWorkItem?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        // A new phrase replaces whatever is still being said.
        cutOff()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let identifier = ObjectIdentifier(utterance)
        logger.info("Saying \"\(text, privacy: .public)\"")

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                currentUtterance = identifier
                pending = continuation
                startWatchdog(for: identifier)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in
                // Only if this phrase is still the one being said.
                if self.currentUtterance == identifier {
                    self.cutOff()
                }
            }
        }
    }

    private func cutOff() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish(currentUtterance)
    }

    /// Resumes the waiting `speak` call, but only for the utterance it is waiting on.
    private func finish(_ identifier: ObjectIdentifier?) {
        guard let identifier, identifier == currentUtterance else {
            return
        }
        currentUtterance = nil
        watchdog?.cancel()
        watchdog = nil

        let continuation = pending
        pending = nil
        continuation?.resume()
    }

    private func startWatchdog(for identifier: ObjectIdentifier) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.logger.error("Speech did not finish in time")
            self?.finish(identifier)
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maximumSeconds, execute: work)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.finish(identifier)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.finish(identifier)
        }
    }
}

/// Wraps any `ObjectLocator` and says out loud how the search went:
/// "Item found." right before guidance (the beeping) starts, and
/// "Object not found. Please turn." when the camera cannot see the object.
/// Other failures (timeout, network) stay silent; the not-found earcon covers them.
final class AnnouncingLocator: ObjectLocator {
    static let foundPhrase = "Item found."
    static let notFoundPhrase = "Object not found. Please turn."

    /// Name to add to `ECHORA_REAL_SERVICES` (Local.xcconfig) to turn the announcements on.
    /// ServiceFlags ignores names it does not know, so it can sit next to the service names.
    static let serviceName = "announcements"
    /// UserDefaults override, e.g. launch argument `-flag.announcements YES`.
    static let defaultsKey = "flag.announcements"

    private let wrapped: ObjectLocator
    private let announcer: SpokenAnnouncing

    init(wrapping wrapped: ObjectLocator, announcer: SpokenAnnouncing) {
        self.wrapped = wrapped
        self.announcer = announcer
    }

    /// `locator` with spoken announcements when they are switched on, otherwise `locator` itself.
    @MainActor
    static func wrapIfEnabled(
        _ locator: ObjectLocator,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> ObjectLocator {
        var override: Bool?
        if defaults.object(forKey: defaultsKey) != nil {
            override = defaults.bool(forKey: defaultsKey)
        }
        let realServices = bundle.object(forInfoDictionaryKey: "ECHORA_REAL_SERVICES") as? String
        guard isEnabled(realServices: realServices ?? "", override: override) else {
            return locator
        }
        return AnnouncingLocator(wrapping: locator, announcer: SpeechAnnouncer())
    }

    /// `realServices` is space or comma separated, case-insensitive (same rule as ServiceFlags).
    /// A UserDefaults `override` wins.
    static func isEnabled(realServices: String, override: Bool?) -> Bool {
        if let override {
            return override
        }
        let separators = CharacterSet(charactersIn: " ,")
        let names = realServices.lowercased().components(separatedBy: separators)
        return names.contains(serviceName)
    }

    // MARK: - ObjectLocator

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        let detection: Detection
        do {
            detection = try await wrapped.locate(utterance: utterance, in: snapshot)
        } catch EchoraError.objectNotFound(let what) {
            // Finish speaking before the error surfaces, so the not-found earcon comes after the words.
            await announcer.speak(Self.notFoundPhrase)
            throw EchoraError.objectNotFound(what)
        }

        try Task.checkCancellation()
        // The coordinator starts the cue as soon as this returns, so wait for the words to end.
        await announcer.speak(Self.foundPhrase)
        return detection
    }
}
