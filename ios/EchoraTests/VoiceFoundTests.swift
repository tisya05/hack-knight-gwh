import XCTest
@testable import Echora

private final class ScriptedVoice: VoiceCommandListening {
    var onPartialTranscript: ((String) -> Void)?
    var transcript = ""

    func requestAuthorization() async -> Bool {
        return true
    }

    func startListening() throws {
    }

    func stopListening() async -> String {
        return transcript
    }
}

/// Blind users end a round by voice instead of a FOUND button.
@MainActor
final class VoiceFoundTests: XCTestCase {
    private var voice = ScriptedVoice()

    private func makeReadyCoordinator() async throws -> EchoraCoordinator {
        voice = ScriptedVoice()
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: MockObjectLocator(),
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: voice,
            telemetry: MockTelemetry()
        )
        let coordinator = EchoraCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        return coordinator
    }

    func testFoundCommandWords() {
        XCTAssertTrue(EchoraCoordinator.isFoundCommand("Found"))
        XCTAssertTrue(EchoraCoordinator.isFoundCommand("found it!"))
        XCTAssertTrue(EchoraCoordinator.isFoundCommand("I got it"))
        XCTAssertFalse(EchoraCoordinator.isFoundCommand("where's my mug"))
        XCTAssertFalse(EchoraCoordinator.isFoundCommand("calibrate"))
        XCTAssertTrue(EchoraCoordinator.isFoundCommand("fund"))
        XCTAssertTrue(EchoraCoordinator.isFoundCommand("Fond."))
        XCTAssertTrue(EchoraCoordinator.isFoundCommand("here it is"))
        XCTAssertTrue(EchoraCoordinator.isFoundCommand("I have it"))
        XCTAssertTrue(EchoraCoordinator.isFoundCommand("done"))
        XCTAssertFalse(EchoraCoordinator.isFoundCommand("where's my phone"))
    }

    func testShortMisheardRepliesCountAsFoundMidRound() {
        XCTAssertTrue(EchoraCoordinator.isLikelyFoundMidRound("fun"))
        XCTAssertTrue(EchoraCoordinator.isLikelyFoundMidRound("sound it"))
        XCTAssertFalse(EchoraCoordinator.isLikelyFoundMidRound("keys"))
        XCTAssertFalse(EchoraCoordinator.isLikelyFoundMidRound("my wallet"))
        XCTAssertFalse(EchoraCoordinator.isLikelyFoundMidRound("where's my coffee"))
        XCTAssertFalse(EchoraCoordinator.isLikelyFoundMidRound("calibrate"))
        XCTAssertFalse(EchoraCoordinator.isLikelyFoundMidRound(""))
    }

    func testSayingFoundEndsRoundAtPressTime() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))

        try await Task.sleep(nanoseconds: 400_000_000)
        voice.transcript = "got it"
        coordinator.beginVoiceRequest()

        // Hold the button a while; that time must NOT count.
        try await Task.sleep(nanoseconds: 500_000_000)
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case .found(let result) = coordinator.state else {
            XCTFail("expected .found, got \(coordinator.state)")
            return
        }
        XCTAssertEqual(result.durationSeconds, 0.4, accuracy: 0.2)
        XCTAssertTrue(result.success)
        coordinator.onDisappear()
    }

    func testSayingFoundWhenIdleDoesNothing() async throws {
        let coordinator = try await makeReadyCoordinator()

        voice.transcript = "found"
        coordinator.beginVoiceRequest()
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coordinator.state, .ready)
        coordinator.onDisappear()
    }
}
