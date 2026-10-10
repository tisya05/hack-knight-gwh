import Foundation

/// Opt-in switches for the demo features that live in Voice/ (`demoObjects`, `announcements`).
/// They ride on `ECHORA_REAL_SERVICES` in Local.xcconfig next to the service names;
/// ServiceFlags ignores names it does not know.
enum VoiceFeatureFlags {
    static func isOn(
        _ name: String,
        defaultsKey: String,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> Bool {
        var override: Bool?
        if defaults.object(forKey: defaultsKey) != nil {
            override = defaults.bool(forKey: defaultsKey)
        }
        let realServices = bundle.object(forInfoDictionaryKey: "ECHORA_REAL_SERVICES") as? String
        return isOn(name, realServices: realServices ?? "", override: override)
    }

    /// `realServices` is space or comma separated, case-insensitive (same rule as ServiceFlags).
    /// A UserDefaults `override` wins.
    static func isOn(_ name: String, realServices: String, override: Bool?) -> Bool {
        if let override {
            return override
        }
        let separators = CharacterSet(charactersIn: " ,")
        let names = realServices.lowercased().components(separatedBy: separators)
        return names.contains(name.lowercased())
    }
}

/// Settings of the ElevenLabs voice agent. The agent itself (prompt, tools, voice)
/// is created once with `scripts/setup_elevenlabs_agent.py`.
enum VoiceAgentConfig {
    static let conversationEndpoint = "wss://api.elevenlabs.io/v1/convai/conversation"

    /// Both directions are 16-bit mono PCM at this rate (the setup script configures the agent to match).
    static let sampleRate: Double = 16_000
    static let audioFormatName = "pcm_16000"

    /// After push-to-talk is released: how long to wait without any sign of life
    /// (speech heard, agent talking) before giving up on the conversation.
    static let idleTimeoutSeconds: TimeInterval = 8
    /// Hard stop measured from the press, whatever happens.
    static let maximumSessionSeconds: TimeInterval = 30

    /// UserDefaults key, e.g. launch argument `-elevenlabs.agentId agent_...`. Wins over Info.plist.
    static let agentIdDefaultsKey = "elevenlabs.agentId"
    /// Info.plist key, filled from the gitignored Secrets.xcconfig.
    static let agentIdInfoKey = "ELEVENLABS_AGENT_ID"
    /// UserDefaults key for the on-screen readout. Defaults to on in debug builds.
    static let debugOverlayDefaultsKey = "voice.debugOverlay"

    /// The agent ID is not an API key, but anyone who has it can spend our minutes:
    /// it stays out of the repo. nil when it is not set.
    static func agentId(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> String? {
        let fromDefaults = defaults.string(forKey: agentIdDefaultsKey)
        let fromBundle = bundle.object(forInfoDictionaryKey: agentIdInfoKey) as? String
        let candidates = [fromDefaults, fromBundle]
        for candidate in candidates {
            guard let candidate else {
                continue
            }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("$(") {
                continue
            }
            return trimmed
        }
        return nil
    }

    static func conversationURL(agentId: String) -> URL? {
        guard var components = URLComponents(string: conversationEndpoint) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "agent_id", value: agentId)
        ]
        return components.url
    }

    static func showsDebugOverlay(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: debugOverlayDefaultsKey) != nil {
            return defaults.bool(forKey: debugOverlayDefaultsKey)
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
