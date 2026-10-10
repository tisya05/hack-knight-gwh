import Foundation

enum Config {
    /// Tested 2026-10-09 on our key: 1.4 s, box accurate to ~0.2%. gemini-3.8-flash was
    /// overloaded (503 / 30 s timeout) and has no "minimal" thinking; 2.5 is closed to new keys.
    static let geminiModel = "gemini-3.6-flash"
    /// Lowest thinking level the model accepts: fastest answers.
    static let geminiThinkingLevel = "minimal"
    static let geminiTimeoutSeconds: TimeInterval = 8
    /// Free-tier guard: refuse requests beyond this many per rolling minute.
    static let geminiMaxRequestsPerMinute = 10
    static let backendBaseURL = URL(string: "https://SET-ME")!
    static let rig = ListenerRig.standInFront(backOffsetMeters: 0.35, upOffsetMeters: 0.30)
    static let fallbackDepthMeters: Float = 0.6
    static let objectCenterLiftMeters: Float = 0.05
    static let onTargetThresholdDegrees: Float = 12
    static let spokenRepeatIntervalSeconds: Double = 4
    static let knownObjects = [
        "mug", "cup", "bottle", "keys", "phone", "wallet",
        "glasses", "remote", "pen", "headphones", "apple"
    ]
    static let defaultFlags = ServiceFlags.allMocks
    static let appVersion = "0.1.0"
}
