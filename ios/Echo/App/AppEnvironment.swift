import Foundation
import os

struct ServiceFlags {
    var mockPerception: Bool
    var mockLocator: Bool
    var mockHeadTracking: Bool
    var mockAudio: Bool
    var mockVoice: Bool
    var mockNarrator: Bool
    var mockTelemetry: Bool

    static let allMocks = ServiceFlags(
        mockPerception: true,
        mockLocator: true,
        mockHeadTracking: true,
        mockAudio: true,
        mockVoice: true,
        mockNarrator: true,
        mockTelemetry: true
    )
}

extension ServiceFlags {
    /// `Config.defaultFlags`, overridden by any values stored in UserDefaults
    /// (written by the Settings screen, or passed as launch arguments such as
    /// `-flag.mockPerception NO` in the Xcode scheme).
    static func current(defaults: UserDefaults = .standard) -> ServiceFlags {
        var flags = Config.defaultFlags
        flags.mockPerception = read("flag.mockPerception", fallback: flags.mockPerception, defaults: defaults)
        flags.mockLocator = read("flag.mockLocator", fallback: flags.mockLocator, defaults: defaults)
        flags.mockHeadTracking = read("flag.mockHeadTracking", fallback: flags.mockHeadTracking, defaults: defaults)
        flags.mockAudio = read("flag.mockAudio", fallback: flags.mockAudio, defaults: defaults)
        flags.mockVoice = read("flag.mockVoice", fallback: flags.mockVoice, defaults: defaults)
        flags.mockNarrator = read("flag.mockNarrator", fallback: flags.mockNarrator, defaults: defaults)
        flags.mockTelemetry = read("flag.mockTelemetry", fallback: flags.mockTelemetry, defaults: defaults)
        return flags
    }

    private static func read(_ key: String, fallback: Bool, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return fallback
        }
        return defaults.bool(forKey: key)
    }
}

@MainActor
final class AppEnvironment {
    let perception: PerceptionService
    let locator: ObjectLocator
    let headTracker: HeadTracking
    let audio: SpatialAudioRendering
    let voice: VoiceCommandListening
    let narrator: DirectionsNarrating
    let telemetry: TelemetryReporting

    init(
        perception: PerceptionService,
        locator: ObjectLocator,
        headTracker: HeadTracking,
        audio: SpatialAudioRendering,
        voice: VoiceCommandListening,
        narrator: DirectionsNarrating,
        telemetry: TelemetryReporting
    ) {
        self.perception = perception
        self.locator = locator
        self.headTracker = headTracker
        self.audio = audio
        self.voice = voice
        self.narrator = narrator
        self.telemetry = telemetry
    }

    /// Picks real or mock per flag. Until a real implementation exists, its flag is forced to mock.
    static func make(flags: ServiceFlags) -> AppEnvironment {
        let logger = Logger(subsystem: "com.gwh.echora", category: "AppEnvironment")
        logger.info("Building environment with flags: \(String(describing: flags), privacy: .public)")

        // Real implementations get wired in here as owners land them.
        let perception: PerceptionService = MockPerceptionService()
        let locator: ObjectLocator = MockObjectLocator()
        let headTracker: HeadTracking = MockHeadTracker()
        let audio: SpatialAudioRendering = MockSpatialAudio()
        let voice: VoiceCommandListening = MockVoiceListener()
        let narrator: DirectionsNarrating = MockDirectionsNarrator()
        let telemetry: TelemetryReporting = MockTelemetry()

        return AppEnvironment(
            perception: perception,
            locator: locator,
            headTracker: headTracker,
            audio: audio,
            voice: voice,
            narrator: narrator,
            telemetry: telemetry
        )
    }
}
