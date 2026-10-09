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
        let echora = valid.filter { $0.mode == .echora }
        let spoken = valid.filter { $0.mode == .spokenDirections }

        let echoraParticipants = Set(echora.map { $0.participantId })
        let spokenParticipants = Set(spoken.map { $0.participantId })
        let bothModes = echoraParticipants.intersection(spokenParticipants)

        let echoraTimes = echora.map { $0.durationSeconds }
        let spokenTimes = spoken.map { $0.durationSeconds }

        let medianEchora = median(echoraTimes)
        let medianSpoken = median(spokenTimes)

        var speedup: Double?
        if let medianEchora, let medianSpoken, medianEchora > 0 {
            speedup = medianSpoken / medianEchora
        }

        return StudyStats(
            participants: bothModes.count,
            echoraRounds: echora.count,
            spokenRounds: spoken.count,
            medianEchoraSeconds: medianEchora,
            medianSpokenSeconds: medianSpoken,
            meanEchoraSeconds: mean(echoraTimes),
            meanSpokenSeconds: mean(spokenTimes),
            speedup: speedup
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
