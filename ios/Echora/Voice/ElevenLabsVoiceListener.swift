import Foundation
import os

/// `VoiceCommandListening` backed by an ElevenLabs conversational agent.
///
/// Push-to-talk press opens a conversation and streams the microphone. The agent
/// works out which object the user means and calls the `find_object` client tool;
/// that object's name is what `stopListening` returns, so the coordinator treats
/// it like any transcript. `mark_found` and `recalibrate` come back as the
/// "found" / "calibrate" voice commands (CONTRACT 3.6).
///
/// Release does not hang up: if the agent has not decided yet (it may be asking
/// "which one?"), the conversation stays open until it does, or until nothing
/// has happened for `idleTimeout`. Calling `stopListening` again cancels the wait.
///
/// Call `startListening` from the main thread. All state is touched on main only,
/// which is what makes the unchecked `Sendable` safe.
final class ElevenLabsVoiceListener: VoiceCommandListening, @unchecked Sendable {
    private enum Phase {
        case idle
        /// Socket opening. Microphone audio is kept until the agent is ready.
        case connecting
        case live
    }

    var onPartialTranscript: ((String) -> Void)?

    private let agentId: String
    private let transport: VoiceAgentTransport
    private let audio: VoiceAgentAudioIO
    private let idleTimeout: TimeInterval
    private let maximumDuration: TimeInterval
    /// Short status lines for the on-screen debug readout.
    private let onStatus: (String) -> Void
    private let logger = Logger(subsystem: "com.gwh.echora", category: "VoiceAgent")

    private var phase = Phase.idle
    /// Bumped per conversation so late callbacks of an old one are ignored.
    private var sessionNumber = 0
    private var bufferedChunks: [Data] = []
    private var outputSampleRate = VoiceAgentConfig.sampleRate
    /// What the agent decided (object name, "found", "calibrate"). The latest call wins.
    private var outcome: String?
    private var lastUserTranscript = ""
    /// Result of a conversation that ended before `stopListening` was called.
    private var unclaimedResult: String?
    private var waiters: [CheckedContinuation<String, Never>] = []
    private var idleTimer: DispatchWorkItem?
    private var hardStopTimer: DispatchWorkItem?

    init(
        agentId: String,
        transport: VoiceAgentTransport,
        audio: VoiceAgentAudioIO,
        idleTimeout: TimeInterval = VoiceAgentConfig.idleTimeoutSeconds,
        maximumDuration: TimeInterval = VoiceAgentConfig.maximumSessionSeconds,
        onStatus: @escaping (String) -> Void = { _ in }
    ) {
        self.agentId = agentId
        self.transport = transport
        self.audio = audio
        self.idleTimeout = idleTimeout
        self.maximumDuration = maximumDuration
        self.onStatus = onStatus
    }

    /// Real socket and microphone. nil when no agent ID is configured
    /// (`ELEVENLABS_AGENT_ID`), so AppEnvironment can fall back to the mock.
    static func makeFromBundle(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> ElevenLabsVoiceListener? {
        guard let agentId = VoiceAgentConfig.agentId(defaults: defaults, bundle: bundle) else {
            return nil
        }

        var onStatus: (String) -> Void = { _ in }
        if VoiceAgentConfig.showsDebugOverlay(defaults: defaults) {
            onStatus = { line in
                // The listener only runs on the main thread.
                MainActor.assumeIsolated {
                    VoiceAgentDebugOverlay.shared.show(line)
                }
            }
        }

        return ElevenLabsVoiceListener(
            agentId: agentId,
            transport: WebSocketVoiceAgentTransport(),
            audio: EngineVoiceAgentAudioIO(),
            onStatus: onStatus
        )
    }

    // MARK: - VoiceCommandListening

    func requestAuthorization() async -> Bool {
        let granted = await audio.requestPermission()
        logger.info("Microphone permission granted: \(granted, privacy: .public)")
        return granted
    }

    func startListening() throws {
        if phase != .idle {
            logger.info("startListening while a conversation is open, dropping the old one")
            finish(with: "")
        }
        guard let url = VoiceAgentConfig.conversationURL(agentId: agentId) else {
            throw EchoraError.speechFailed("Bad ElevenLabs agent ID")
        }

        sessionNumber += 1
        let session = sessionNumber
        bufferedChunks = []
        outcome = nil
        lastUserTranscript = ""
        unclaimedResult = nil
        outputSampleRate = VoiceAgentConfig.sampleRate

        try audio.startCapture { [weak self] chunk in
            DispatchQueue.main.async {
                self?.handleChunk(chunk, session: session)
            }
        }

        transport.onText = { [weak self] text in
            self?.handleText(text, session: session)
        }
        transport.onClose = { [weak self] reason in
            self?.handleClose(reason: reason, session: session)
        }
        transport.connect(to: url)
        transport.send(VoiceAgentMessages.initiation())
        phase = .connecting

        hardStopTimer = schedule(after: maximumDuration) { [weak self] in
            self?.handleTimeout(session: session, reason: "hard stop")
        }
        logger.info("Conversation \(session, privacy: .public) opening")
        onStatus("connecting…")
    }

    func stopListening() async -> String {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.resolveStop(continuation)
            }
        }
    }

    private func resolveStop(_ continuation: CheckedContinuation<String, Never>) {
        if phase == .idle {
            // Never started, or the conversation already ended on its own.
            let result = unclaimedResult ?? ""
            unclaimedResult = nil
            continuation.resume(returning: result)
            return
        }
        if !waiters.isEmpty {
            // Second call while the first is still waiting for the agent: cancel.
            logger.info("stopListening called again, cancelling the conversation")
            waiters.append(continuation)
            finish(with: "")
            return
        }

        waiters.append(continuation)
        if let outcome {
            finish(with: outcome)
            return
        }
        logger.info("Released before the agent decided, waiting up to \(self.idleTimeout, privacy: .public) s")
        restartIdleTimer()
    }

    // MARK: - Conversation events

    private func handleChunk(_ chunk: Data, session: Int) {
        guard session == sessionNumber else {
            return
        }
        switch phase {
        case .idle:
            return
        case .connecting:
            bufferedChunks.append(chunk)
        case .live:
            transport.send(VoiceAgentMessages.audioChunk(chunk))
        }
    }

    private func handleText(_ text: String, session: Int) {
        guard session == sessionNumber, phase != .idle else {
            return
        }
        guard let event = VoiceAgentMessages.parse(text) else {
            logger.error("Unreadable message from the agent")
            return
        }

        switch event {
        case .metadata(let conversationId, let outputFormat, let inputFormat):
            handleMetadata(conversationId: conversationId, outputFormat: outputFormat, inputFormat: inputFormat)
        case .userTranscript(let transcript):
            logger.info("Heard \"\(transcript, privacy: .public)\"")
            lastUserTranscript = transcript
            onPartialTranscript?(transcript)
            onStatus("heard \"\(transcript)\"")
            noteActivity()
        case .agentResponse(let response):
            logger.info("Agent says \"\(response, privacy: .public)\"")
            onStatus("agent: \(response)")
            noteActivity()
        case .audio(let pcm):
            audio.play(pcm, sampleRate: outputSampleRate)
            noteActivity()
        case .interruption:
            audio.flushPlayback()
        case .ping(let eventId):
            transport.send(VoiceAgentMessages.pong(eventId: eventId))
        case .toolCall(let name, let callId, let parameters, let expectsResponse):
            handleToolCall(name: name, callId: callId, parameters: parameters, expectsResponse: expectsResponse)
        case .other:
            break
        }
    }

    private func handleMetadata(conversationId: String, outputFormat: String, inputFormat: String) {
        logger.info("Conversation \(conversationId, privacy: .public) live, in \(inputFormat, privacy: .public), out \(outputFormat, privacy: .public)")

        guard inputFormat == VoiceAgentConfig.audioFormatName else {
            logger.error("Agent expects \(inputFormat, privacy: .public) input, the app sends \(VoiceAgentConfig.audioFormatName, privacy: .public). Re-run scripts/setup_elevenlabs_agent.py.")
            onStatus("agent audio format mismatch")
            finish(with: "")
            return
        }
        if let rate = VoiceAgentMessages.sampleRate(fromFormat: outputFormat) {
            outputSampleRate = rate
        } else {
            logger.error("Agent voice format \(outputFormat, privacy: .public) is not PCM, its voice will not play")
        }

        phase = .live
        transport.send(VoiceAgentMessages.availableObjectsUpdate(names: DemoObjectCatalog.names))
        for chunk in bufferedChunks {
            transport.send(VoiceAgentMessages.audioChunk(chunk))
        }
        bufferedChunks = []
        onStatus("listening")
    }

    private func handleToolCall(
        name: String,
        callId: String,
        parameters: [String: String],
        expectsResponse: Bool
    ) {
        let transcript = VoiceAgentTool.transcript(toolName: name, parameters: parameters)
        logger.info("Agent called \(name, privacy: .public) \(String(describing: parameters), privacy: .public) -> \(transcript ?? "unusable", privacy: .public)")
        noteActivity()

        guard let transcript else {
            if expectsResponse {
                let available = DemoObjectCatalog.names.joined(separator: ", ")
                let message = "Unknown object. Available objects: \(available). Ask the user which one."
                transport.send(VoiceAgentMessages.toolResult(callId: callId, result: message, isError: true))
            }
            onStatus("\(name): not a demo object")
            return
        }

        if expectsResponse {
            transport.send(VoiceAgentMessages.toolResult(callId: callId, result: "ok", isError: false))
        }
        outcome = transcript
        onStatus("\(name) -> \(transcript)")

        // Still holding push-to-talk: keep the result for the release.
        if !waiters.isEmpty {
            finish(with: transcript)
        }
    }

    private func handleClose(reason: String, session: Int) {
        guard session == sessionNumber, phase != .idle else {
            return
        }
        logger.error("Conversation closed: \(reason, privacy: .public)")
        onStatus("closed: \(reason)")
        finish(with: bestAvailableResult())
    }

    private func handleTimeout(session: Int, reason: String) {
        guard session == sessionNumber, phase != .idle else {
            return
        }
        logger.info("Conversation timed out (\(reason, privacy: .public))")
        finish(with: bestAvailableResult())
    }

    /// The agent's decision if there is one. Otherwise the last thing the user said:
    /// the coordinator and the locator can still make sense of "where's my mug" or "found it".
    private func bestAvailableResult() -> String {
        if let outcome {
            return outcome
        }
        return lastUserTranscript
    }

    // MARK: - Ending

    /// Hangs up and hands `result` to whoever is waiting in `stopListening`.
    private func finish(with result: String) {
        idleTimer?.cancel()
        idleTimer = nil
        hardStopTimer?.cancel()
        hardStopTimer = nil

        transport.onText = nil
        transport.onClose = nil
        transport.close()
        audio.stop()
        phase = .idle
        bufferedChunks = []
        logger.info("Conversation ended with \"\(result, privacy: .public)\"")

        let waiting = waiters
        waiters = []
        if waiting.isEmpty {
            unclaimedResult = result
            return
        }
        for continuation in waiting {
            continuation.resume(returning: result)
        }
    }

    /// The idle countdown only runs after release. Anything the user or agent does restarts it.
    private func noteActivity() {
        guard !waiters.isEmpty else {
            return
        }
        restartIdleTimer()
    }

    private func restartIdleTimer() {
        idleTimer?.cancel()
        let session = sessionNumber
        idleTimer = schedule(after: idleTimeout) { [weak self] in
            self?.handleTimeout(session: session, reason: "idle")
        }
    }

    private func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }
}
