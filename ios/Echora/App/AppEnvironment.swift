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
    /// Layered, last wins:
    /// 1. `Config.defaultFlags` (all mocks on main).
    /// 2. Info.plist `ECHORA_REAL_SERVICES`, set per person in the gitignored
    ///    `ios/Config/Local.xcconfig`, e.g. `ECHORA_REAL_SERVICES = perception audio`.
    /// 3. UserDefaults (Settings screen, or launch arguments like `-flag.mockPerception NO`).
    static func current(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> ServiceFlags {
        var flags = Config.defaultFlags
        let realServices = bundle.object(forInfoDictionaryKey: "ECHORA_REAL_SERVICES") as? String
        flags = flags.applyingRealServices(realServices ?? "")
        flags.mockPerception = read("flag.mockPerception", fallback: flags.mockPerception, defaults: defaults)
        flags.mockLocator = read("flag.mockLocator", fallback: flags.mockLocator, defaults: defaults)
        flags.mockHeadTracking = read("flag.mockHeadTracking", fallback: flags.mockHeadTracking, defaults: defaults)
        flags.mockAudio = read("flag.mockAudio", fallback: flags.mockAudio, defaults: defaults)
        flags.mockVoice = read("flag.mockVoice", fallback: flags.mockVoice, defaults: defaults)
        flags.mockNarrator = read("flag.mockNarrator", fallback: flags.mockNarrator, defaults: defaults)
        flags.mockTelemetry = read("flag.mockTelemetry", fallback: flags.mockTelemetry, defaults: defaults)
        return flags
    }

    /// Turns the named services real. `list` is space or comma separated, case-insensitive.
    func applyingRealServices(_ list: String) -> ServiceFlags {
        var flags = self
        let separators = CharacterSet(charactersIn: " ,")
        let names = list.lowercased().components(separatedBy: separators)
        for name in names {
            switch name {
            case "perception":
                flags.mockPerception = false
            case "locator":
                flags.mockLocator = false
            case "headtracking":
                flags.mockHeadTracking = false
            case "audio":
                flags.mockAudio = false
            case "voice":
                flags.mockVoice = false
            case "narrator":
                flags.mockNarrator = false
            case "telemetry":
                flags.mockTelemetry = false
            default:
                continue
            }
        }
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
        let perception = makePerception(useMock: flags.mockPerception, logger: logger)
        let locator = makeLocator(useMock: flags.mockLocator, logger: logger)
        let headTracker = makeHeadTracker(useMock: flags.mockHeadTracking, logger: logger)
        let audio = makeAudio(useMock: flags.mockAudio, logger: logger)
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

    private static func makePerception(useMock: Bool, logger: Logger) -> PerceptionService {
        if useMock {
            return MockPerceptionService()
        }
        guard ARSessionController.isSupported else {
            logger.warning("Real perception requested but ARKit world tracking is unsupported (simulator?). Using mock.")
            return MockPerceptionService()
        }
        logger.info("Using real ARSessionController")
        return ARSessionController()
    }

    private static func makeHeadTracker(useMock: Bool, logger: Logger) -> HeadTracking {
        if useMock {
            return MockHeadTracker()
        }
        logger.info("Using real HeadTracker")
        return HeadTracker()
    }

    private static func makeAudio(useMock: Bool, logger: Logger) -> SpatialAudioRendering {
        if useMock {
            return MockSpatialAudio()
        }
        logger.info("Using real SpatialAudioEngine")
        return SpatialAudioEngine()
    }

    private static func makeLocator(useMock: Bool, logger: Logger) -> ObjectLocator {
        if useMock {
            return MockObjectLocator()
        }
        guard let gemini = GeminiLocator.makeFromBundle() else {
            logger.warning("Real locator requested but GEMINI_API_KEY is empty (ios/Config/Secrets.xcconfig). Using mock.")
            return MockObjectLocator()
        }
        logger.info("Using real GeminiLocator (\(Config.geminiModel, privacy: .public))")
        return gemini
    }
}
