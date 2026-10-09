import XCTest
@testable import Echora

final class MockTelemetryStatsTests: XCTestCase {
    private func round(
        _ participant: String,
        _ mode: RoundMode,
        _ seconds: Double,
        success: Bool = true,
        practice: Bool = false
    ) -> RoundResult {
        RoundResult(
            id: UUID(),
            participantId: participant,
            mode: mode,
            objectLabel: "mug",
            durationSeconds: seconds,
            success: success,
            isPractice: practice,
            headTrackingUsed: false,
            placement: .manualTap,
            startedAt: Date(),
            appVersion: "test"
        )
    }

    func testStatsRules() {
        let rounds = [
            round("P01", .spokenDirections, 10),
            round("P01", .echora, 4),
            round("P02", .spokenDirections, 14),
            round("P02", .echora, 6),
            round("P03", .echora, 5),                       // only one mode
            round("P04", .echora, 100, practice: true),     // excluded
            round("P04", .spokenDirections, 1, success: false) // excluded
        ]
        let stats = MockTelemetry.computeStats(rounds)

        XCTAssertEqual(stats.participants, 2)
        XCTAssertEqual(stats.echoraRounds, 3)
        XCTAssertEqual(stats.spokenRounds, 2)
        XCTAssertEqual(stats.medianEchoraSeconds ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(stats.medianSpokenSeconds ?? 0, 12, accuracy: 1e-9)
        XCTAssertEqual(stats.speedup ?? 0, 12.0 / 5.0, accuracy: 1e-9)
    }

    func testSpeedupNilWithoutBothModes() {
        let stats = MockTelemetry.computeStats([round("P01", .echora, 4)])
        XCTAssertNil(stats.speedup)
        XCTAssertNil(stats.medianSpokenSeconds)
    }
}
