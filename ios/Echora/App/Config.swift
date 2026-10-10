import Foundation

enum Config {
    /// Raced in order (see GeminiLocator: hedged requests). Measured on our key: both answer in ~1.3-1.8 s with boxes within
    /// ~0.2% when healthy, but gemini-3.6-flash spiked to 8-22 s at night while 3.5 stayed fast.
    /// gemini-3.8-flash was overloaded and rejects "minimal"; 2.5 is closed to new keys.
    static let geminiModels = ["gemini-3.5-flash", "gemini-3.6-flash"]
    static let geminiModel = geminiModels[0]
    /// Lowest thinking level the models accept: fastest answers.
    static let geminiThinkingLevel = "minimal"
    /// If the first model has not answered after this, the next model is asked in parallel.
    static let geminiHedgeDelaySeconds: TimeInterval = 2.5
    /// Whole request budget (all models). The coordinator adds 1 s on top.
    static let geminiTimeoutSeconds: TimeInterval = 14
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
