import XCTest
@testable import Echora

private final class FakeTransport: VoiceAgentTransport {
    var onText: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    var connectedURL: URL?
    var sent: [String] = []
    var closeCount = 0

    func connect(to url: URL) {
        connectedURL = url
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close() {
        closeCount += 1
    }

    /// Messages of one "type" the listener sent, decoded.
    func sentObjects(ofType type: String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for text in sent {
            guard let data = text.data(using: .utf8) else {
                continue
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            if object["type"] as? String == type {
                result.append(object)
            }
        }
        return result
    }

    var sentAudioChunks: [String] {
        var result: [String] = []
        for text in sent where text.contains("user_audio_chunk") {
            result.append(text)
        }
        return result
    }
}

private final class FakeAudio: VoiceAgentAudioIO {
    var startError: Error?
    var onChunk: ((Data) -> Void)?
    var isCapturing = false
    var played: [Data] = []
    var playedSampleRate: Double?
    var flushCount = 0

    func requestPermission() async -> Bool {
        return true
    }

    func startCapture(onChunk: @escaping (Data) -> Void) throws {
        if let startError {
            throw startError
        }
        self.onChunk = onChunk
        isCapturing = true
    }

    func stop() {
        isCapturing = false
    }

    func play(_ pcm: Data, sampleRate: Double) {
        played.append(pcm)
        playedSampleRate = sampleRate
    }

    func flushPlayback() {
        flushCount += 1
    }
}

@MainActor
final class ElevenLabsVoiceListenerTests: XCTestCase {
    private var transport = FakeTransport()
    private var audio = FakeAudio()

    private static let metadata = """
    {"type":"conversation_initiation_metadata","conversation_initiation_metadata_event":\
    {"conversation_id":"conv_1","agent_output_audio_format":"pcm_24000","user_input_audio_format":"pcm_16000"}}
    """

    private func makeListener(
        idleTimeout: TimeInterval = 5,
        maximumDuration: TimeInterval = 5
    ) -> ElevenLabsVoiceListener {
        transport = FakeTransport()
        audio = FakeAudio()
        return ElevenLabsVoiceListener(
            agentId: "agent_test",
            transport: transport,
            audio: audio,
            idleTimeout: idleTimeout,
            maximumDuration: maximumDuration
        )
    }

    private static func toolCall(_ name: String, object: String? = nil, expectsResponse: Bool = true) -> String {
        var parameters = "{}"
        if let object {
            parameters = "{\"object\":\"\(object)\"}"
        }
        return """
        {"type":"client_tool_call","client_tool_call":{"tool_name":"\(name)","tool_call_id":"call_1",\
        "parameters":\(parameters),"expects_response":\(expectsResponse)}}
        """
    }

    private static func userTranscript(_ text: String) -> String {
        return """
        {"type":"user_transcript","user_transcription_event":{"user_transcript":"\(text)","event_id":1}}
        """
    }

    /// Lets work queued on the main queue (microphone chunks, stopListening) run.
    private func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    // MARK: - Opening

    func testPressOpensTheAgentConversation() throws {
        let listener = makeListener()
        try listener.startListening()

        XCTAssertEqual(
            transport.connectedURL?.absoluteString,
            "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent_test"
        )
        XCTAssertEqual(transport.sentObjects(ofType: "conversation_initiation_client_data").count, 1)
        XCTAssertTrue(audio.isCapturing)
    }

    func testMicrophoneFailureIsThrownAndNothingConnects() {
        let listener = makeListener()
        audio.startError = EchoraError.speechNotAuthorized

        XCTAssertThrowsError(try listener.startListening()) { error in
            XCTAssertEqual(error as? EchoraError, .speechNotAuthorized)
        }
        XCTAssertNil(transport.connectedURL)
    }

    func testSpeechBeforeTheAgentIsReadyIsNotLost() async throws {
        let listener = makeListener()
        try listener.startListening()

        audio.onChunk?(Data([1, 2]))
        audio.onChunk?(Data([3, 4]))
        await drainMainQueue()
        XCTAssertTrue(transport.sentAudioChunks.isEmpty)

        transport.onText?(Self.metadata)
        XCTAssertEqual(transport.sentAudioChunks.count, 2)
        XCTAssertEqual(transport.sentObjects(ofType: "contextual_update").count, 1)

        audio.onChunk?(Data([5, 6]))
        await drainMainQueue()
        XCTAssertEqual(transport.sentAudioChunks.count, 3)
    }

    // MARK: - Results

    func testObjectChosenWhileHoldingIsReturnedOnRelease() async throws {
        let listener = makeListener()
        try listener.startListening()
        transport.onText?(Self.metadata)
        transport.onText?(Self.toolCall("find_object", object: "cup"))

        // Still holding: the conversation stays open.
        XCTAssertEqual(transport.closeCount, 0)

        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "mug")
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertFalse(audio.isCapturing)

        let results = transport.sentObjects(ofType: "client_tool_result")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["is_error"] as? Bool, false)
    }

    func testReleaseWaitsForTheAgentToDecide() async throws {
        let listener = makeListener()
        try listener.startListening()
        transport.onText?(Self.metadata)

        async let pending = listener.stopListening()
        await drainMainQueue()
        XCTAssertEqual(transport.closeCount, 0)

        transport.onText?(Self.toolCall("find_object", object: "keys"))
        let transcript = await pending
        XCTAssertEqual(transcript, "keys")
    }

    func testFoundAndRecalibrateBecomeVoiceCommands() async throws {
        let listener = makeListener()

        try listener.startListening()
        transport.onText?(Self.metadata)
        transport.onText?(Self.toolCall("mark_found", expectsResponse: false))
        let found = await listener.stopListening()
        XCTAssertTrue(EchoraCoordinator.isFoundCommand(found))
        XCTAssertTrue(transport.sentObjects(ofType: "client_tool_result").isEmpty)

        try listener.startListening()
        transport.onText?(Self.metadata)
        transport.onText?(Self.toolCall("recalibrate", expectsResponse: false))
        let calibrate = await listener.stopListening()
        XCTAssertTrue(EchoraCoordinator.isCalibrateCommand(calibrate))
    }

    func testUnknownObjectIsSentBackToTheAgent() async throws {
        let listener = makeListener(idleTimeout: 0.1)
        try listener.startListening()
        transport.onText?(Self.metadata)
        transport.onText?(Self.toolCall("find_object", object: "stapler"))

        let results = transport.sentObjects(ofType: "client_tool_result")
        XCTAssertEqual(results.first?["is_error"] as? Bool, true)
        XCTAssertEqual(transport.closeCount, 0)

        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "")
    }

    func testIdleTimeoutFallsBackToWhatTheUserSaid() async throws {
        let listener = makeListener(idleTimeout: 0.1)
        var partials: [String] = []
        listener.onPartialTranscript = { text in
            partials.append(text)
        }

        try listener.startListening()
        transport.onText?(Self.metadata)
        transport.onText?(Self.userTranscript("where is my wallet"))

        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "where is my wallet")
        XCTAssertEqual(partials, ["where is my wallet"])
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testHardStopWhileHoldingKeepsTheResultForTheRelease() async throws {
        let listener = makeListener(maximumDuration: 0.1)
        try listener.startListening()
        transport.onText?(Self.metadata)
        transport.onText?(Self.toolCall("find_object", object: "bottle"))

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertFalse(audio.isCapturing)

        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "bottle")
    }

    func testSecondStopCancelsTheWait() async throws {
        let listener = makeListener()
        try listener.startListening()
        transport.onText?(Self.metadata)

        async let first = listener.stopListening()
        await drainMainQueue()
        let second = await listener.stopListening()
        let firstResult = await first

        XCTAssertEqual(firstResult, "")
        XCTAssertEqual(second, "")
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testSocketClosingEndsTheWait() async throws {
        let listener = makeListener()
        try listener.startListening()

        async let pending = listener.stopListening()
        await drainMainQueue()
        transport.onClose?("no network")

        let transcript = await pending
        XCTAssertEqual(transcript, "")
        XCTAssertFalse(audio.isCapturing)
    }

    func testStopWithoutStartReturnsEmpty() async {
        let listener = makeListener()
        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "")
    }

    // MARK: - Agent voice and keep-alive

    func testAgentVoiceIsPlayedAtTheAgentsRate() throws {
        let listener = makeListener()
        try listener.startListening()
        transport.onText?(Self.metadata)

        let pcm = Data([9, 8, 7, 6])
        transport.onText?("{\"type\":\"audio\",\"audio_event\":{\"audio_base_64\":\"\(pcm.base64EncodedString())\",\"event_id\":2}}")
        XCTAssertEqual(audio.played, [pcm])
        XCTAssertEqual(audio.playedSampleRate, 24_000)

        transport.onText?("{\"type\":\"interruption\",\"interruption_event\":{\"event_id\":2}}")
        XCTAssertEqual(audio.flushCount, 1)
    }

    func testPingIsAnswered() throws {
        let listener = makeListener()
        try listener.startListening()
        transport.onText?("{\"type\":\"ping\",\"ping_event\":{\"event_id\":77}}")

        let pongs = transport.sentObjects(ofType: "pong")
        XCTAssertEqual(pongs.first?["event_id"] as? Int, 77)
    }

    func testWrongInputFormatEndsTheConversation() async throws {
        let listener = makeListener()
        try listener.startListening()
        transport.onText?("""
        {"type":"conversation_initiation_metadata","conversation_initiation_metadata_event":\
        {"conversation_id":"c","agent_output_audio_format":"pcm_16000","user_input_audio_format":"ulaw_8000"}}
        """)

        XCTAssertEqual(transport.closeCount, 1)
        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "")
    }

    // MARK: - Whole flow

    /// Say an object to the agent -> the coordinator guides to that object.
    func testAgentChoiceStartsGuidanceToTheDemoObject() async throws {
        let listener = makeListener()
        // In front of the mock camera (identity transform, looking down -Z).
        let glasses = DemoObject(name: "glasses", aliases: [], worldPosition: SIMD3<Float>(0, 0, -0.6))
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: DemoObjectLocator(objects: [glasses]),
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: listener,
            telemetry: MockTelemetry()
        )
        let coordinator = EchoraCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)

        coordinator.beginVoiceRequest()
        XCTAssertEqual(coordinator.state, .listening)
        transport.onText?(Self.metadata)
        transport.onText?(Self.toolCall("find_object", object: "glasses"))
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 500_000_000)

        guard case .guiding(let target, let round) = coordinator.state else {
            XCTFail("Expected guiding, got \(coordinator.state)")
            return
        }
        XCTAssertEqual(target.label, "glasses")
        XCTAssertEqual(round.objectLabel, "glasses")
        XCTAssertEqual(coordinator.debug.lastDetection?.label, "glasses")
        coordinator.onDisappear()
    }
}
