import XCTest
import simd
@testable import Echora

private final class ScriptedLocator: ObjectLocator {
    var error: Error?
    private(set) var callCount = 0

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        callCount += 1
        if let error {
            throw error
        }
        let box = NormalizedRect(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6)
        return Detection(label: utterance, box: box, confidence: 1.0)
    }
}

/// Records what was said, and what the app was doing while it was being said.
@MainActor
private final class RecordingAnnouncer: SpokenAnnouncing {
    private(set) var spoken: [String] = []
    var onSpeak: (() -> Void)?

    func speak(_ text: String) async {
        onSpeak?()
        spoken.append(text)
    }
}

@MainActor
final class AnnouncingLocatorTests: XCTestCase {
    private let snapshot = DemoObjectCatalogTests.makeSnapshot(transform: matrix_identity_float4x4)

    func testSaysItemFoundAndReturnsTheDetection() async throws {
        let wrapped = ScriptedLocator()
        let announcer = RecordingAnnouncer()
        let locator = AnnouncingLocator(wrapping: wrapped, announcer: announcer)

        let detection = try await locator.locate(utterance: "mug", in: snapshot)

        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(announcer.spoken, ["Item found."])
    }

    func testSaysPleaseTurnWhenTheObjectIsNotSeen() async {
        let wrapped = ScriptedLocator()
        wrapped.error = EchoraError.objectNotFound("mug")
        let announcer = RecordingAnnouncer()
        let locator = AnnouncingLocator(wrapping: wrapped, announcer: announcer)

        do {
            _ = try await locator.locate(utterance: "mug", in: snapshot)
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
                _ = try await locator.locate(utterance: "mug", in: snapshot)
                XCTFail("Expected \(failure)")
            } catch {
                XCTAssertEqual(error as? EchoraError, failure)
            }
            XCTAssertTrue(announcer.spoken.isEmpty, "\(failure)")
        }
    }

    func testOffByDefaultAndOnByOverride() {
        let suiteName = "AnnouncingLocatorTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("No test defaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let plain = ScriptedLocator()

        let untouched = AnnouncingLocator.wrapIfEnabled(plain, defaults: defaults, bundle: Bundle(for: Self.self))
        XCTAssertTrue(untouched === plain)

        defaults.set(true, forKey: AnnouncingLocator.defaultsKey)
        let wrapped = AnnouncingLocator.wrapIfEnabled(plain, defaults: defaults, bundle: Bundle(for: Self.self))
        XCTAssertTrue(wrapped is AnnouncingLocator)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - With the coordinator

    private func makeReadyCoordinator(
        objects: [DemoObject],
        announcer: RecordingAnnouncer
    ) async throws -> EchoraCoordinator {
        let locator = AnnouncingLocator(
            wrapping: DemoObjectLocator(objects: objects),
            announcer: announcer
        )
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: locator,
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: MockVoiceListener(),
            telemetry: MockTelemetry()
        )
        let coordinator = EchoraCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        return coordinator
    }

    /// "Item found" comes before the beeping: while it is spoken the round has not started.
    func testItemFoundIsSpokenBeforeGuidanceStarts() async throws {
        // In front of the mock camera (identity transform, looking down -Z).
        let mug = DemoObject(name: "mug", aliases: [], worldPosition: SIMD3<Float>(0, 0, -0.6))
        let announcer = RecordingAnnouncer()
        let coordinator = try await makeReadyCoordinator(objects: [mug], announcer: announcer)

        var stateWhileSpeaking: EchoraState?
        announcer.onSpeak = {
            stateWhileSpeaking = coordinator.state
        }

        coordinator.submitTypedRequest("mug")
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(announcer.spoken, ["Item found."])
        XCTAssertEqual(stateWhileSpeaking, .locating(utterance: "mug"))
        guard case .guiding(let target, _) = coordinator.state else {
            XCTFail("Expected guiding, got \(coordinator.state)")
            return
        }
        XCTAssertEqual(target.label, "mug")
        coordinator.onDisappear()
    }

    func testFacingAwaySaysPleaseTurnAndNoRoundStarts() async throws {
        // Behind the mock camera.
        let mug = DemoObject(name: "mug", aliases: [], worldPosition: SIMD3<Float>(0, 0, 0.6))
        let announcer = RecordingAnnouncer()
        let coordinator = try await makeReadyCoordinator(objects: [mug], announcer: announcer)

        coordinator.submitTypedRequest("mug")
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(announcer.spoken, ["Object not found. Please turn."])
        XCTAssertEqual(coordinator.state, .error(.objectNotFound("mug")))
        XCTAssertNil(coordinator.elapsedSeconds)
        coordinator.onDisappear()
    }
}
