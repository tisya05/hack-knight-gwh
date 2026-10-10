import Foundation
import os

/// Logs each prompt instead of playing it. Used until Seoyeon's VoicePromptPlayer lands.
final class MockVoicePromptPlayer: VoicePromptPlaying {
    private(set) var played: [VoicePrompt] = []

    private let logger = Logger(subsystem: "com.gwh.echora", category: "MockVoicePrompt")

    func play(_ prompt: VoicePrompt) async {
        logger.info("play \(prompt.clipName, privacy: .public)")
        played.append(prompt)
    }

    func stop() {
        logger.info("stop")
    }
}
