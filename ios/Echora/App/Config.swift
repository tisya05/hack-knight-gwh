import Foundation

enum Config {
    static let geminiModel = "SET-ME-newest-flash-model"
    static let geminiTimeoutSeconds: TimeInterval = 8
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
