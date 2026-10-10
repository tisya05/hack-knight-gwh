import Foundation
import os

/// Real `ObjectLocator` (CONTRACT 4.2): one Gemini call per request that both
/// interprets what the user wants and finds it in the upright snapshot.
/// Model fallback: if a model is slow, overloaded (503) or rate-limited (429), the
/// same request goes to the next model in `Config.geminiModels`. Real answers
/// (found / not found / malformed) never fall through.
/// Request building and response parsing are static and unit tested with fixtures.
final class GeminiLocator: ObjectLocator {
    private let apiKey: String
    private let models: [String]
    private let attemptTimeouts: [TimeInterval]
    private let protocolClasses: [AnyClass]?
    private var rateLimiter: RequestRateLimiter
    private let logger = Logger(subsystem: "com.gwh.echora", category: "GeminiLocator")

    init(
        apiKey: String,
        models: [String] = Config.geminiModels,
        attemptTimeouts: [TimeInterval] = Config.geminiAttemptTimeouts,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.apiKey = apiKey
        self.models = models
        self.attemptTimeouts = attemptTimeouts
        self.protocolClasses = protocolClasses
        self.rateLimiter = RequestRateLimiter(
            maximumRequests: Config.geminiMaxRequestsPerMinute,
            window: 60
        )
    }

    /// One session per attempt so each attempt gets its own total time limit.
    private func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let protocolClasses {
            // Unit tests stub the network here.
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    private func timeout(forAttempt index: Int) -> TimeInterval {
        if index < attemptTimeouts.count {
            return attemptTimeouts[index]
        }
        return attemptTimeouts.last ?? 8
    }

    /// Reads `GEMINI_API_KEY` from Info.plist (filled from the gitignored Secrets.xcconfig).
    /// nil when it is missing, so AppEnvironment can fall back to the mock.
    static func makeFromBundle(_ bundle: Bundle = .main) -> GeminiLocator? {
        guard let key = bundle.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") {
            return nil
        }
        return GeminiLocator(apiKey: trimmed)
    }

    // MARK: - ObjectLocator

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        var lastError = EchoraError.locatorFailed("No Gemini models configured")

        for (index, model) in models.enumerated() {
            guard rateLimiter.allowRequest(at: Date()) else {
                logger.warning("Gemini request refused by the per-minute guard")
                throw EchoraError.locatorFailed("Too many requests, wait a moment")
            }

            do {
                return try await attempt(
                    model: model,
                    timeout: timeout(forAttempt: index),
                    utterance: utterance,
                    jpeg: snapshot.uprightJPEG
                )
            } catch AttemptFailure.tryNextModel(let error) {
                logger.warning("\(model, privacy: .public) unavailable (\(String(describing: error), privacy: .public)), trying next model")
                lastError = error
            }
        }
        throw lastError
    }

    /// Slow / overloaded / rate-limited: worth asking the next model.
    private enum AttemptFailure: Error {
        case tryNextModel(EchoraError)
    }

    private func attempt(
        model: String,
        timeout: TimeInterval,
        utterance: String,
        jpeg: Data
    ) async throws -> Detection {
        let request = try makeURLRequest(model: model, utterance: utterance, jpeg: jpeg)
        let session = makeSession(timeout: timeout)
        defer {
            session.finishTasksAndInvalidate()
        }
        let started = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            logger.error("\(model, privacy: .public) timed out after \(timeout, privacy: .public) s")
            throw AttemptFailure.tryNextModel(.locatorTimeout)
        } catch {
            logger.error("Gemini network error: \(error.localizedDescription, privacy: .public)")
            throw EchoraError.locatorFailed(error.localizedDescription)
        }

        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("\(model, privacy: .public) HTTP \(status, privacy: .public) in \(latencyMs, privacy: .public) ms")

        guard status == 200 else {
            let error = Self.httpError(status: status, body: data)
            if status == 429 || status == 503 {
                throw AttemptFailure.tryNextModel(error)
            }
            throw error
        }

        let detection = try Self.parseResponse(data)
        logger.info("\(model, privacy: .public) found \(detection.label, privacy: .public) at \(String(describing: detection.box), privacy: .public)")
        return detection
    }

    // MARK: - Request

    static let prompt = """
    You are the vision module of an object-finding aid for blind users.
    The user said: "{utterance}"
    1. Decide which single physical object they want.
    2. Find that object in the image.
    3. If several match, choose the one nearest the camera.
    Return JSON only.
    box_2d is [ymin, xmin, ymax, xmax], integers normalized to 0-1000, tightly around the object.
    If the object is not visible, set found to false, leave box_2d empty, and explain briefly in reason.
    """

    private func makeURLRequest(model: String, utterance: String, jpeg: Data) throws -> URLRequest {
        let base = "https://generativelanguage.googleapis.com/v1beta/models/"
        guard let url = URL(string: base + model + ":generateContent") else {
            throw EchoraError.locatorFailed("Bad model name")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(
            utterance: utterance,
            jpeg: jpeg,
            thinkingLevel: Config.geminiThinkingLevel
        )
        return request
    }

    static func requestBody(utterance: String, jpeg: Data, thinkingLevel: String) throws -> Data {
        let text = prompt.replacingOccurrences(of: "{utterance}", with: utterance)

        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "found": ["type": "BOOLEAN"],
                "label": ["type": "STRING"],
                "box_2d": ["type": "ARRAY", "items": ["type": "INTEGER"]],
                "confidence": ["type": "NUMBER"],
                "reason": ["type": "STRING"]
            ],
            "required": ["found", "label"]
        ]

        let imagePart: [String: Any] = [
            "inline_data": [
                "mime_type": "image/jpeg",
                "data": jpeg.base64EncodedString()
            ]
        ]
        let textPart: [String: Any] = ["text": text]

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [imagePart, textPart]
                ]
            ],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
                "responseSchema": schema,
                "thinkingConfig": ["thinkingLevel": thinkingLevel]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Response

    private struct Envelope: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        let candidates: [Candidate]?
    }

    private struct Answer: Decodable {
        let found: Bool
        let label: String
        let box2d: [Int]?
        let confidence: Double?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case found
            case label
            case box2d = "box_2d"
            case confidence
            case reason
        }
    }

    /// Parses a generateContent response into a Detection in UPRIGHT normalized space.
    /// Throws .objectNotFound when Gemini says found = false, .locatorFailed on anything malformed.
    static func parseResponse(_ data: Data) throws -> Detection {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw EchoraError.locatorFailed("Unreadable response")
        }

        guard let candidate = envelope.candidates?.first else {
            throw EchoraError.locatorFailed("No candidates")
        }
        let parts = candidate.content?.parts ?? []
        // Skip thought summaries if a thinking model includes them.
        let answerPart = parts.first { part in
            part.text != nil && part.thought != true
        }
        guard let text = answerPart?.text, let answerData = text.data(using: .utf8) else {
            let reason = candidate.finishReason ?? "empty"
            throw EchoraError.locatorFailed("No answer (\(reason))")
        }

        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: answerData)
        } catch {
            throw EchoraError.locatorFailed("Answer is not the expected JSON")
        }

        guard answer.found else {
            let reason = answer.reason ?? answer.label
            throw EchoraError.objectNotFound(reason)
        }
        let box = try normalizedBox(from: answer.box2d ?? [])

        var confidence = answer.confidence
        if let value = confidence {
            confidence = min(max(value, 0), 1)
        }
        return Detection(label: answer.label, box: box, confidence: confidence)
    }

    /// Gemini box_2d is [ymin, xmin, ymax, xmax] on 0...1000. Nothing else in the app sees it.
    static func normalizedBox(from values: [Int]) throws -> NormalizedRect {
        guard values.count == 4 else {
            throw EchoraError.locatorFailed("box_2d needs 4 values, got \(values.count)")
        }
        for value in values {
            if value < 0 || value > 1000 {
                throw EchoraError.locatorFailed("box_2d value \(value) outside 0...1000")
            }
        }

        let ymin = values[0]
        let xmin = values[1]
        let ymax = values[2]
        let xmax = values[3]
        guard xmin < xmax, ymin < ymax else {
            throw EchoraError.locatorFailed("box_2d min is not below max")
        }

        return NormalizedRect(
            minX: Double(xmin) / 1000.0,
            minY: Double(ymin) / 1000.0,
            maxX: Double(xmax) / 1000.0,
            maxY: Double(ymax) / 1000.0
        )
    }

    static func httpError(status: Int, body: Data) -> EchoraError {
        if status == 429 {
            return .locatorFailed("Gemini rate limit reached, wait a minute")
        }
        if status == 503 {
            return .locatorFailed("Gemini is overloaded, try again")
        }
        var message = "HTTP \(status)"
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let text = error["message"] as? String {
            message += ": " + text
        }
        return .locatorFailed(message)
    }
}

/// Sliding-window request counter. Value type with an injected clock so it is unit tested.
struct RequestRateLimiter {
    let maximumRequests: Int
    let window: TimeInterval
    private(set) var timestamps: [Date] = []

    init(maximumRequests: Int, window: TimeInterval) {
        self.maximumRequests = maximumRequests
        self.window = window
    }

    /// Records and allows the request if under the limit; otherwise refuses without recording.
    mutating func allowRequest(at now: Date) -> Bool {
        timestamps = timestamps.filter { stamp in
            now.timeIntervalSince(stamp) < window
        }
        if timestamps.count >= maximumRequests {
            return false
        }
        timestamps.append(now)
        return true
    }
}
