import AVFoundation
import os

/// Microphone in, agent voice out, behind a protocol so the listener is unit tested without audio hardware.
/// Call every method from the main thread.
protocol VoiceAgentAudioIO: AnyObject {
    func requestPermission() async -> Bool
    /// Starts the microphone. `onChunk` gets 16-bit mono PCM at `VoiceAgentConfig.sampleRate`
    /// and is called on an audio thread.
    func startCapture(onChunk: @escaping (Data) -> Void) throws
    func stop()
    /// Queues a piece of the agent's voice (16-bit mono PCM).
    func play(_ pcm: Data, sampleRate: Double)
    /// Drops the agent audio still queued (the user spoke over it).
    func flushPlayback()
}

/// Own `AVAudioEngine` for the voice agent (CONTRACT 4.5): an input tap for the
/// microphone and a plain, non-spatial player for the agent's voice.
/// It never configures `AVAudioSession`; the Audio module owns that, so the real
/// audio service has to be running (it sets `.playAndRecord`).
final class EngineVoiceAgentAudioIO: VoiceAgentAudioIO {
    private struct PlaybackState {
        var pendingBuffers = 0
        /// Bumped on every flush, so completion handlers of flushed buffers are ignored.
        var generation = 0
        /// True when the agent plays through the phone speaker: the microphone
        /// would hear it, so capture is silenced while the agent talks.
        var mutesMicrophoneWhilePlaying = false
    }

    private let logger = Logger(subsystem: "com.gwh.echora", category: "VoiceAgentAudio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isPlayerAttached = false
    private var playbackFormat: AVAudioFormat?
    private var hasTap = false

    private let lock = NSLock()
    private var playbackState = PlaybackState()

    func requestPermission() async -> Bool {
        return await AVAudioApplication.requestRecordPermission()
    }

    func startCapture(onChunk: @escaping (Data) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw EchoraError.speechNotAuthorized
        }
        // Checked before touching inputNode: without a record-capable session
        // (mock audio, or the simulator's playback-only category) there is no input to tap.
        guard session.category == .playAndRecord, session.isInputAvailable else {
            throw EchoraError.speechFailed("No microphone. The voice agent needs the real audio service on a device.")
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw EchoraError.speechFailed("Microphone format is not ready")
        }
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: VoiceAgentConfig.sampleRate,
            channels: 1,
            interleaved: true
        )
        guard let targetFormat, let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw EchoraError.speechFailed("Cannot convert microphone audio")
        }

        try connectPlayerIfNeeded(sampleRate: VoiceAgentConfig.sampleRate)

        lock.lock()
        playbackState.pendingBuffers = 0
        playbackState.generation += 1
        playbackState.mutesMicrophoneWhilePlaying = !AudioSessionConfigurator.isHeadphoneOutput()
        lock.unlock()

        removeTapIfNeeded()
        // About 50 ms per buffer at 48 kHz. The system may pick another size.
        input.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            guard let self else {
                return
            }
            guard let chunk = self.convert(buffer, with: converter, to: targetFormat) else {
                return
            }
            onChunk(chunk)
        }
        hasTap = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            removeTapIfNeeded()
            throw EchoraError.speechFailed("Voice engine failed to start: \(error.localizedDescription)")
        }
        player.play()
        logger.info("Capture started. Mic \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch. Output: \(AudioSessionConfigurator.outputRouteDescription(), privacy: .public)")
    }

    func stop() {
        removeTapIfNeeded()
        player.stop()
        engine.stop()

        lock.lock()
        playbackState.pendingBuffers = 0
        playbackState.generation += 1
        lock.unlock()
        logger.info("Capture stopped")
    }

    func play(_ pcm: Data, sampleRate: Double) {
        guard engine.isRunning else {
            return
        }
        do {
            try connectPlayerIfNeeded(sampleRate: sampleRate)
        } catch {
            logger.error("Cannot play agent audio: \(String(describing: error), privacy: .public)")
            return
        }
        guard let format = playbackFormat, let buffer = Self.makeBuffer(fromPCM16: pcm, format: format) else {
            return
        }

        lock.lock()
        playbackState.pendingBuffers += 1
        let generation = playbackState.generation
        lock.unlock()

        player.scheduleBuffer(buffer) { [weak self] in
            self?.bufferFinished(generation: generation)
        }
        if !player.isPlaying {
            player.play()
        }
    }

    func flushPlayback() {
        lock.lock()
        playbackState.pendingBuffers = 0
        playbackState.generation += 1
        lock.unlock()

        player.stop()
        if engine.isRunning {
            player.play()
        }
    }

    // MARK: - Playback

    private func connectPlayerIfNeeded(sampleRate: Double) throws {
        if let current = playbackFormat, current.sampleRate == sampleRate {
            return
        }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
        guard let format else {
            throw EchoraError.speechFailed("Unsupported agent audio rate \(sampleRate)")
        }

        if !isPlayerAttached {
            engine.attach(player)
            isPlayerAttached = true
        } else {
            player.stop()
            engine.disconnectNodeOutput(player)
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playbackFormat = format
    }

    private func bufferFinished(generation: Int) {
        lock.lock()
        if generation == playbackState.generation && playbackState.pendingBuffers > 0 {
            playbackState.pendingBuffers -= 1
        }
        lock.unlock()
    }

    /// 16-bit little-endian mono PCM -> a float buffer the player node accepts.
    static func makeBuffer(fromPCM16 pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else {
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        guard let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        pcm.withUnsafeBytes { rawBytes in
            for index in 0..<frameCount {
                let sample = rawBytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                channel[index] = Float(Int16(littleEndian: sample)) / 32768.0
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }

    // MARK: - Capture

    private func removeTapIfNeeded() {
        guard hasTap else {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        hasTap = false
    }

    /// Runs on the audio thread. Resamples one microphone buffer to 16-bit mono PCM.
    private func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> Data? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            return nil
        }

        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0, let samples = output.int16ChannelData?[0] else {
            return nil
        }

        lock.lock()
        let isMuted = playbackState.mutesMicrophoneWhilePlaying && playbackState.pendingBuffers > 0
        lock.unlock()
        if isMuted {
            // Keep the stream's timing, but do not let the agent hear itself.
            return Data(count: byteCount)
        }
        return Data(bytes: samples, count: byteCount)
    }
}
