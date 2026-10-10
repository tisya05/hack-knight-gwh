import Foundation

enum Config {
    /// Raced in order (see GeminiLocator: hedged requests).
    /// Free-tier daily limits on our key (AI Studio rate-limit page, 2026-10-10): every
    /// "Flash" model is capped at 20 requests/day, the "Flash Lite" models at 500/day.
    /// Measured on the test image: 3.5-flash-lite 1.1 s, 3.1-flash-lite 3.1 s, both with
    /// boxes within ~0.3% of truth, same as the full Flash models.
    static let geminiModels = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]
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
    /// Where the ears are relative to the phone. No stand: the phone is held against the
    /// chest, so the ears are ~35 cm straight above it. (With a stand in front of the user,
    /// use .standInFront(backOffsetMeters: 0.35, upOffsetMeters: 0.30).)
    static let rig = ListenerRig.chestMount(upOffsetMeters: 0.35)
    static let fallbackDepthMeters: Float = 0.6
    /// Non-LiDAR placements sit on the table; the sound is raised to the object's middle.
    /// The lift is half the object's estimated height (RayMath.centerLift), clamped to
    /// minimum...maximum. objectCenterLiftMeters is the fallback when it can't be estimated.
    static let objectCenterLiftMeters: Float = 0.05
    static let minimumObjectCenterLiftMeters: Float = 0.005
    static let maximumObjectCenterLiftMeters: Float = 0.10
    static let onTargetThresholdDegrees: Float = 12
    static let knownObjects = [
        "mug", "cup", "bottle", "keys", "phone", "wallet",
        "glasses", "remote", "pen", "headphones", "apple"
    ]
    static let defaultFlags = ServiceFlags.allMocks
    static let appVersion = "0.1.0"
}
