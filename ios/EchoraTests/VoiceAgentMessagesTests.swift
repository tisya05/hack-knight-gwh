import XCTest
@testable import Echora

/// Fixtures follow the ElevenLabs Agents WebSocket reference.
final class VoiceAgentMessagesTests: XCTestCase {

    // MARK: - Server -> client

    func testParsesMetadata() {
        let json = """
        {"type":"conversation_initiation_metadata","conversation_initiation_metadata_event":\
        {"conversation_id":"conv_123","agent_output_audio_format":"pcm_24000","user_input_audio_format":"pcm_16000"}}
        """
        let expected = VoiceAgentServerEvent.metadata(
            conversationId: "conv_123",
            outputFormat: "pcm_24000",
            inputFormat: "pcm_16000"
        )
        XCTAssertEqual(VoiceAgentMessages.parse(json), expected)
    }

    func testParsesUserTranscript() {
        let json = """
        {"type":"user_transcript","user_transcription_event":{"user_transcript":"where's my mug","event_id":4}}
        """
        XCTAssertEqual(VoiceAgentMessages.parse(json), .userTranscript("where's my mug"))
    }

    func testParsesAgentResponse() {
        let json = """
        {"type":"agent_response","agent_response_event":{"agent_response":"Which one?","event_id":5}}
        """
        XCTAssertEqual(VoiceAgentMessages.parse(json), .agentResponse("Which one?"))
    }

    func testParsesAudio() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let json = """
        {"type":"audio","audio_event":{"audio_base_64":"\(pcm.base64EncodedString())","event_id":7}}
        """
        XCTAssertEqual(VoiceAgentMessages.parse(json), .audio(pcm))
    }

    func testParsesPingAndInterruption() {
        let ping = """
        {"type":"ping","ping_event":{"event_id":42,"ping_ms":80}}
        """
        let interruption = """
        {"type":"interruption","interruption_event":{"event_id":9}}
        """
        XCTAssertEqual(VoiceAgentMessages.parse(ping), .ping(eventId: 42))
        XCTAssertEqual(VoiceAgentMessages.parse(interruption), .interruption)
    }

    func testParsesToolCall() {
        let json = """
        {"type":"client_tool_call","client_tool_call":{"tool_name":"find_object","tool_call_id":"call_1",\
        "parameters":{"object":"mug"},"event_id":11,"expects_response":true}}
        """
        let expected = VoiceAgentServerEvent.toolCall(
            name: "find_object",
            callId: "call_1",
            parameters: ["object": "mug"],
            expectsResponse: true
        )
        XCTAssertEqual(VoiceAgentMessages.parse(json), expected)
    }

    func testToolCallWithoutParametersOrExpectsResponse() {
        let json = """
        {"type":"client_tool_call","client_tool_call":{"tool_name":"mark_found","tool_call_id":"call_2"}}
        """
        let expected = VoiceAgentServerEvent.toolCall(
            name: "mark_found",
            callId: "call_2",
            parameters: [:],
            expectsResponse: false
        )
        XCTAssertEqual(VoiceAgentMessages.parse(json), expected)
    }

    func testUnusedAndBrokenMessages() {
        let vad = """
        {"type":"vad_score","vad_score_event":{"vad_score":0.9}}
        """
        XCTAssertEqual(VoiceAgentMessages.parse(vad), .other("vad_score"))
        XCTAssertNil(VoiceAgentMessages.parse("not json"))
        XCTAssertNil(VoiceAgentMessages.parse("{\"no_type\":1}"))
    }

    func testSampleRateFromFormat() {
        XCTAssertEqual(VoiceAgentMessages.sampleRate(fromFormat: "pcm_16000"), 16_000)
        XCTAssertEqual(VoiceAgentMessages.sampleRate(fromFormat: "pcm_48000"), 48_000)
        XCTAssertNil(VoiceAgentMessages.sampleRate(fromFormat: "ulaw_8000"))
    }

    // MARK: - Client -> server

    func testAudioChunkHasNoTypeField() throws {
        let pcm = Data([0x10, 0x20, 0x30, 0x40])
        let object = try Self.decode(VoiceAgentMessages.audioChunk(pcm))

        XCTAssertEqual(object["user_audio_chunk"] as? String, pcm.base64EncodedString())
        XCTAssertNil(object["type"])
    }

    func testPong() throws {
        let object = try Self.decode(VoiceAgentMessages.pong(eventId: 42))
        XCTAssertEqual(object["type"] as? String, "pong")
        XCTAssertEqual(object["event_id"] as? Int, 42)
    }

    func testToolResult() throws {
        let message = VoiceAgentMessages.toolResult(callId: "call_1", result: "ok", isError: false)
        let object = try Self.decode(message)

        XCTAssertEqual(object["type"] as? String, "client_tool_result")
        XCTAssertEqual(object["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(object["result"] as? String, "ok")
        XCTAssertEqual(object["is_error"] as? Bool, false)
    }

    func testInitiationAndObjectsUpdate() throws {
        let initiation = try Self.decode(VoiceAgentMessages.initiation())
        XCTAssertEqual(initiation["type"] as? String, "conversation_initiation_client_data")

        let update = try Self.decode(VoiceAgentMessages.availableObjectsUpdate(names: ["mug", "keys"]))
        let text = try XCTUnwrap(update["text"] as? String)
        XCTAssertEqual(update["type"] as? String, "contextual_update")
        XCTAssertTrue(text.contains("mug, keys"))
    }

    // MARK: - Tools

    func testToolCallsBecomeCoordinatorTranscripts() {
        let find = VoiceAgentTool.transcript(toolName: "find_object", parameters: ["object": "Cup"])
        let found = VoiceAgentTool.transcript(toolName: "mark_found", parameters: [:])
        let calibrate = VoiceAgentTool.transcript(toolName: "recalibrate", parameters: [:])

        XCTAssertEqual(find, "mug")
        XCTAssertTrue(EchoraCoordinator.isFoundCommand(found ?? ""))
        XCTAssertTrue(EchoraCoordinator.isCalibrateCommand(calibrate ?? ""))
    }

    func testUnusableToolCalls() {
        XCTAssertNil(VoiceAgentTool.transcript(toolName: "find_object", parameters: ["object": "stapler"]))
        XCTAssertNil(VoiceAgentTool.transcript(toolName: "find_object", parameters: [:]))
        XCTAssertNil(VoiceAgentTool.transcript(toolName: "order_pizza", parameters: [:]))
    }

    private static func decode(_ message: String) throws -> [String: Any] {
        let data = try XCTUnwrap(message.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
