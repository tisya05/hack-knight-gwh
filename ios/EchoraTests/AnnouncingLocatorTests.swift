import XCTest
import simd
@testable import Echora

private final class ScriptedLocator: ObjectLocator {
    var error: Error?
    private(set) var utterances: [String] = []

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        utterances.append(utterance)
        if let error {
            throw error
        }
        let box = NormalizedRect(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6)
        return Detection(label: "mug", box: box, confidence: 1.0)
    }
}

/// Records what was said, and lets a test look at the app while it is being said.
@MainActor
private final class RecordingAnnouncer: SpokenAnnouncing {
    private(set) var spoken: [String] = []
    var onSpeak: (() -> Void)?

    func speak(_ text: String) async {
        onSpeak?()
        spoken.append(text)
    }
}

private final class SpeechBackendStub: SpeechRecognitionBackend {
    var onResult: ((String, Bool) -> Void)?

    func requestAuthorization() async -> Bool {
        return true
    }

    func start(
        contextualStrings: [String],
        onResult: @escaping (String, Bool) -> Void,
        onEnd: @escaping () -> Void
    ) throws {
        self.onResult = onResult
    }

    func endAudio() {
    }

    func cancel() {
    }
}

@MainActor
final class AnnouncingLocatorTests: XCTestCase {
    private static func makeSnapshot() -> Snapshot {
        return Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: Data(),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3,
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: .portrait,
            depth: nil
        )
    }

    func testSaysItemFoundAndReturnsTheDetection() async throws {
        let announcer = RecordingAnnouncer()
        let locator = AnnouncingLocator(wrapping: ScriptedLocator(), announcer: announcer)

        let detection = try await locator.locate(utterance: "where's my mug", in: Self.makeSnapshot())

        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(announcer.spoken, ["Item found."])
    }

    func testSaysPleaseTurnWhenTheObjectIsNotSeen() async {
        let wrapped = ScriptedLocator()
        wrapped.error = EchoraError.objectNotFound("mug")
        let announcer = RecordingAnnouncer()
        let locator = AnnouncingLocator(wrapping: wrapped, announcer: announcer)

        do {
            _ = try await locator.locate(utterance: "mug", in: Self.makeSnapshot())
            XCTFail("Expected objectNotFound")
        } catch {
            XCTAssertEqual(error as? EchoraError, .objectNotFound("mug"))
        }
        XCTAssertEqual(announcer.spoken, ["Object not found. Please turn."])
    }

    func testOtherFailuresStaySilent() async {
        let failures: [EchoraError] = [.locatorTimeout, .locatorFailed("503")]
        for failure in failures {
            let wrapped = ScriptedLocator()
            wrapped.error = failure
            let announcer = RecordingAnnouncer()
            let locator = AnnouncingLocator(wrapping: wrapped, announcer: announcer)

            do {
                _ = try await locator.locate(utterance: "mug", in: Self.makeSnapshot())
                XCTFail("Expected \(failure)")
            } catch {
                XCTAssertEqual(error as? EchoraError, failure)
            }
            XCTAssertTrue(announcer.spoken.isEmpty, "\(failure)")
        }
    }

    func testSwitchedOnByNameOrOverride() {
        XCTAssertTrue(AnnouncingLocator.isEnabled(realServices: "perception audio announcements", override: nil))
        XCTAssertTrue(AnnouncingLocator.isEnabled(realServices: "voice,ANNOUNCEMENTS", override: nil))
        XCTAssertFalse(AnnouncingLocator.isEnabled(realServices: "perception audio", override: nil))
        XCTAssertFalse(AnnouncingLocator.isEnabled(realServices: "announcements", override: false))
        XCTAssertTrue(AnnouncingLocator.isEnabled(realServices: "", override: true))
    }

    func testWrapIfEnabledIsOffByDefault() {
        let suiteName = "AnnouncingLocatorTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("No test defaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let plain = ScriptedLocator()
        let testBundle = Bundle(for: Self.self)

        let untouched = AnnouncingLocator.wrapIfEnabled(plain, defaults: defaults, bundle: testBundle)
        XCTAssertTrue(untouched === plain)

        defaults.set(true, forKey: AnnouncingLocator.defaultsKey)
        let wrapped = AnnouncingLocator.wrapIfEnabled(plain, defaults: defaults, bundle: testBundle)
        XCTAssertTrue(wrapped is AnnouncingLocator)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Whole flow: say an object -> it becomes the target

    private func makeReadyCoordinator(
        locator: ScriptedLocator,
        announcer: RecordingAnnouncer,
        backend: SpeechBackendStub
    ) async throws -> EchoraCoordinator {
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: AnnouncingLocator(wrapping: locator, announcer: announcer),
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: VoiceCommandListener(backend: backend),
            telemetry: MockTelemetry()
        )
        let coordinator = EchoraCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        return coordinator
    }

    /// "Item found" comes before the beeping: while it is spoken the round has not started.
    func testSpokenObjectIsFoundAnnouncedAndThenGuided() async throws {
        let locator = ScriptedLocator()
        let announcer = RecordingAnnouncer()
        let backend = SpeechBackendStub()
        let coordinator = try await makeReadyCoordinator(locator: locator, announcer: announcer, backend: backend)

        var stateWhileSpeaking: EchoraState?
        announcer.onSpeak = {
            stateWhileSpeaking = coordinator.state
        }

        coordinator.beginVoiceRequest()
        XCTAssertEqual(coordinator.state, .listening)
        backend.onResult?("where's my mug", false)
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 100_000_000)
        backend.onResult?("where's my mug", true)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(locator.utterances, ["where's my mug"])
        XCTAssertEqual(announcer.spoken, ["Item found."])
        XCTAssertEqual(stateWhileSpeaking, .locating(utterance: "where's my mug"))
        guard case .guiding(let target, _) = coordinator.state else {
            XCTFail("Expected guiding, got \(coordinator.state)")
            return
        }
        XCTAssertEqual(target.label, "mug")
        XCTAssertNotNil(coordinator.elapsedSeconds)
        coordinator.onDisappear()
    }

    func testObjectOutOfViewSaysPleaseTurnAndNoRoundStarts() async throws {
        let locator = ScriptedLocator()
        locator.error = EchoraError.objectNotFound("mug")
        let announcer = RecordingAnnouncer()
        let backend = SpeechBackendStub()
        let coordinator = try await makeReadyCoordinator(locator: locator, announcer: announcer, backend: backend)

        coordinator.beginVoiceRequest()
        backend.onResult?("find my mug", true)
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(announcer.spoken, ["Object not found. Please turn."])
        XCTAssertEqual(coordinator.state, .error(.objectNotFound("mug")))
        XCTAssertNil(coordinator.elapsedSeconds)
        coordinator.onDisappear()
    }
}
