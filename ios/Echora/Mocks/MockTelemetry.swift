import Foundation
import os

final class MockTelemetry: TelemetryReporting {
    private(set) var results: [RoundResult] = []
    let pendingCount = 0

    private let logger = Logger(subsystem: "com.gwh.echora", category: "MockTelemetry")

    func report(_ result: RoundResult) async {
        logger.info("report \(result.mode.rawValue, privacy: .public) \(result.durationSeconds, privacy: .public) s")
        let alreadyStored = results.contains { $0.id == result.id }
        if !alreadyStored {
            results.append(result)
        }
    }

    func fetchStats() async -> StudyStats? {
        return Self.computeStats(results)
    }

    func ping() async -> Bool {
        return true
    }

    /// Same rules as the backend (CONTRACT Part 5).
    static func computeStats(_ rounds: [RoundResult]) -> StudyStats {
        let valid = rounds.filter { $0.success && !$0.isPractice }
        let participants = Set(valid.map { $0.participantId })
        let times = valid.map { $0.durationSeconds }

        return StudyStats(
            participants: participants.count,
            echoraRounds: valid.count,
            medianEchoraSeconds: median(times),
            meanEchoraSeconds: mean(times)
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let total = values.reduce(0, +)
        return total / Double(values.count)
    }
}
