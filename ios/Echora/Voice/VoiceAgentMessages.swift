import Foundation

/// What the ElevenLabs agent sends over the conversation WebSocket.
enum VoiceAgentServerEvent: Equatable {
    /// First message of a conversation. Formats look like "pcm_16000".
    case metadata(conversationId: String, outputFormat: String, inputFormat: String)
    case userTranscript(String)
    case agentResponse(String)
    /// The agent's voice: 16-bit mono PCM.
    case audio(Data)
    /// The user spoke over the agent: drop the audio still queued.
    case interruption
    case ping(eventId: Int)
    case toolCall(name: String, callId: String, parameters: [String: String], expectsResponse: Bool)
    /// A message type we do not use (vad_score, agent_response_correction, ...).
    case other(String)
}

/// Wire format of the ElevenLabs Agents WebSocket
/// (https://elevenlabs.io/docs/agents-platform/api-reference/agents-platform/websocket).
/// Pure, unit tested with fixtures.
enum VoiceAgentMessages {

    // MARK: - Server -> client

    /// nil when `text` is not a JSON object with a "type".
    static func parse(_ text: String) -> VoiceAgentServerEvent? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard let type = root["type"] as? String else {
            return nil
        }

        switch type {
        case "conversation_initiation_metadata":
            return parseMetadata(root["conversation_initiation_metadata_event"] as? [String: Any])
        case "user_transcript":
            let event = root["user_transcription_event"] as? [String: Any]
            let transcript = event?["user_transcript"] as? String
            return .userTranscript(transcript ?? "")
        case "agent_response":
            let event = root["agent_response_event"] as? [String: Any]
            let response = event?["agent_response"] as? String
            return .agentResponse(response ?? "")
        case "audio":
            return parseAudio(root["audio_event"] as? [String: Any])
        case "interruption":
            return .interruption
        case "ping":
            let event = root["ping_event"] as? [String: Any]
            guard let eventId = event?["event_id"] as? Int else {
                return .other(type)
            }
            return .ping(eventId: eventId)
        case "client_tool_call":
            return parseToolCall(root["client_tool_call"] as? [String: Any])
        default:
            return .other(type)
        }
    }

    private static func parseMetadata(_ event: [String: Any]?) -> VoiceAgentServerEvent {
        let conversationId = event?["conversation_id"] as? String
        let outputFormat = event?["agent_output_audio_format"] as? String
        let inputFormat = event?["user_input_audio_format"] as? String
        return .metadata(
            conversationId: conversationId ?? "",
            outputFormat: outputFormat ?? VoiceAgentConfig.audioFormatName,
            inputFormat: inputFormat ?? VoiceAgentConfig.audioFormatName
        )
    }

    private static func parseAudio(_ event: [String: Any]?) -> VoiceAgentServerEvent {
        guard let encoded = event?["audio_base_64"] as? String else {
            return .other("audio")
        }
        guard let pcm = Data(base64Encoded: encoded) else {
            return .other("audio")
        }
        return .audio(pcm)
    }

    private static func parseToolCall(_ call: [String: Any]?) -> VoiceAgentServerEvent {
        guard let call else {
            return .other("client_tool_call")
        }
        guard let name = call["tool_name"] as? String, let callId = call["tool_call_id"] as? String else {
            return .other("client_tool_call")
        }

        var parameters: [String: String] = [:]
        let rawParameters = call["parameters"] as? [String: Any] ?? [:]
        for (key, value) in rawParameters {
            if let string = value as? String {
                parameters[key] = string
            } else {
                parameters[key] = String(describing: value)
            }
        }

        let expectsResponse = call["expects_response"] as? Bool ?? false
        return .toolCall(
            name: name,
            callId: callId,
            parameters: parameters,
            expectsResponse: expectsResponse
        )
    }

    /// "pcm_16000" -> 16000. nil for anything that is not raw PCM (e.g. "ulaw_8000").
    static func sampleRate(fromFormat format: String) -> Double? {
        let prefix = "pcm_"
        guard format.hasPrefix(prefix) else {
            return nil
        }
        return Double(format.dropFirst(prefix.count))
    }

    // MARK: - Client -> server

    /// Must be the first message of a conversation.
    static func initiation() -> String {
        return encode(["type": "conversation_initiation_client_data"])
    }

    /// Background information for the agent. Does not interrupt it or trigger a reply.
    static func contextualUpdate(_ text: String) -> String {
        return encode(["type": "contextual_update", "text": text])
    }

    /// Tells the agent which objects exist right now, so the catalog in the app is the source of truth.
    static func availableObjectsUpdate(names: [String]) -> String {
        let list = names.joined(separator: ", ")
        return contextualUpdate("Objects available right now: \(list). Use exactly these names with find_object.")
    }

    /// Microphone audio: 16-bit mono PCM. This message has no "type" field.
    static func audioChunk(_ pcm: Data) -> String {
        // Base64 needs no JSON escaping, so skip JSONSerialization on this hot path (~20 messages/s).
        return "{\"user_audio_chunk\":\"\(pcm.base64EncodedString())\"}"
    }

    static func pong(eventId: Int) -> String {
        return encode(["type": "pong", "event_id": eventId])
    }

    static func toolResult(callId: String, result: String, isError: Bool) -> String {
        return encode([
            "type": "client_tool_result",
            "tool_call_id": callId,
            "result": result,
            "is_error": isError
        ])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// The client tools the agent can call, and what each one means to the coordinator.
/// Names must match `scripts/setup_elevenlabs_agent.py`.
enum VoiceAgentTool {
    static let findObject = "find_object"
    static let markFound = "mark_found"
    static let recalibrate = "recalibrate"
    static let objectParameter = "object"

    /// The transcript the coordinator gets for a tool call: the canonical object name,
    /// or the "found" / "calibrate" voice commands it already understands (CONTRACT 3.6).
    /// nil when the call is not usable (unknown tool, or an object outside the demo set).
    static func transcript(toolName: String, parameters: [String: String]) -> String? {
        switch toolName {
        case findObject:
            let requested = parameters[objectParameter] ?? ""
            return DemoObjectCatalog.resolve(requested)?.name
        case markFound:
            return "found"
        case recalibrate:
            return "calibrate"
        default:
            return nil
        }
    }
}
