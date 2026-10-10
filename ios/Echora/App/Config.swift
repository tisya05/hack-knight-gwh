import Foundation

enum Config {
    /// Tried in order. A model that is slow (> geminiAttemptTimeoutSeconds), overloaded (503)
    /// or rate-limited (429) falls through to the next one. Tested on our key 2026-10-09/10:
    /// both answer in ~1.3 s with boxes within ~0.2% when healthy, but each has had 8 s+
    /// spikes. gemini-3.8-flash was overloaded and rejects "minimal"; 2.5 is closed to new keys.
    static let geminiModels = ["gemini-3.6-flash", "gemini-3.5-flash"]
    static let geminiModel = geminiModels[0]
    /// Lowest thinking level the models accept: fastest answers.
    static let geminiThinkingLevel = "minimal"
    /// Per model attempt. Two attempts stay under geminiTimeoutSeconds.
    static let geminiAttemptTimeoutSeconds: TimeInterval = 4
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
