import Foundation
import os

/// Real `ObjectLocator` (CONTRACT 4.2): one Gemini call per request that both
/// interprets what the user wants and finds it in the upright snapshot.
/// Hedged requests: Gemini latency on our key swings between ~1.5 s and 20+ s at random.
/// The first model is asked immediately; if it has not answered after `hedgeDelay`, or it
/// fails with a timeout / 503 / 429, the next model is asked IN PARALLEL. The first real
/// answer wins and the other request is cancelled. Real answers (found / not found /
/// malformed) end the race; only "slow or unavailable" lets another model try.
/// Request building and response parsing are static and unit tested with fixtures.
final class GeminiLocator: ObjectLocator {
    private let apiKey: String
    private let models: [String]
    private let hedgeDelay: TimeInterval
    private let budget: TimeInterval
    private let protocolClasses: [AnyClass]?
    private var rateLimiter: RequestRateLimiter
    private let logger = Logger(subsystem: "com.gwh.echora", category: "GeminiLocator")

    init(
        apiKey: String,
        models: [String] = Config.geminiModels,
        hedgeDelay: TimeInterval = Config.geminiHedgeDelaySeconds,
        budget: TimeInterval = Config.geminiTimeoutSeconds,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.apiKey = apiKey
        self.models = models
        self.hedgeDelay = hedgeDelay
        self.budget = budget
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
        guard !models.isEmpty else {
            throw EchoraError.locatorFailed("No Gemini models configured")
        }
        let started = Date()
        let jpeg = snapshot.uprightJPEG

        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            var nextModelIndex = 0
            var running = 0
            var lastError = EchoraError.locatorTimeout

            /// Starts the next model if there is one and the free-tier guard allows it.
            func launchNextModel() throws {
                guard nextModelIndex < models.count else {
                    return
                }
                guard rateLimiter.allowRequest(at: Date()) else {
                    logger.warning("Gemini request refused by the per-minute guard")
                    if running == 0 {
                        throw EchoraError.locatorFailed("Too many requests, wait a moment")
                    }
                    return
                }

                let model = models[nextModelIndex]
                nextModelIndex += 1
                running += 1
                let remaining = max(budget - Date().timeIntervalSince(started), 0.5)
                group.addTask {
                    await self.attempt(model: model, timeout: remaining, utterance: utterance, jpeg: jpeg)
                }

                if nextModelIndex < models.count {
                    let delay = hedgeDelay
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        return .hedgeTimerFired
                    }
                }
            }

            try launchNextModel()

            while let outcome = try await group.next() {
                switch outcome {
                case .answer(let detection):
                    group.cancelAll()
                    return detection
                case .finalError(let error):
                    group.cancelAll()
                    throw error
                case .slowOrUnavailable(let model, let error):
                    running -= 1
                    lastError = error
                    logger.warning("\(model, privacy: .public) slow/unavailable (\(String(describing: error), privacy: .public))")
                    try launchNextModel()
                    if running == 0 && nextModelIndex >= models.count {
                        group.cancelAll()
                        throw lastError
                    }
                case .hedgeTimerFired:
                    if nextModelIndex < models.count {
                        logger.info("No answer after \(self.hedgeDelay, privacy: .public) s, racing the next model")
                        try launchNextModel()
                    }
                }
            }
            throw lastError
        }
    }

    private enum Outcome {
        case answer(Detection)
        /// A real answer that is not a detection (not found, malformed, bad request). Ends the race.
        case finalError(EchoraError)
        /// Timeout / 503 / 429: another model may still answer.
        case slowOrUnavailable(model: String, error: EchoraError)
        case hedgeTimerFired
    }

    private func attempt(
        model: String,
        timeout: TimeInterval,
        utterance: String,
        jpeg: Data
    ) async -> Outcome {
        let request: URLRequest
        do {
            request = try makeURLRequest(model: model, utterance: utterance, jpeg: jpeg)
        } catch {
            return .finalError(.locatorFailed("Bad request"))
        }
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
            return .slowOrUnavailable(model: model, error: .locatorTimeout)
        } catch let error as URLError where error.code == .cancelled {
            // The other model won the race.
            return .slowOrUnavailable(model: model, error: .locatorTimeout)
        } catch {
            if Task.isCancelled {
                return .slowOrUnavailable(model: model, error: .locatorTimeout)
            }
            logger.error("Gemini network error: \(error.localizedDescription, privacy: .public)")
            return .finalError(.locatorFailed(error.localizedDescription))
        }

        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("\(model, privacy: .public) HTTP \(status, privacy: .public) in \(latencyMs, privacy: .public) ms")

        guard status == 200 else {
            let error = Self.httpError(status: status, body: data)
            if status == 429 || status == 503 {
                return .slowOrUnavailable(model: model, error: error)
            }
            return .finalError(error)
        }

        do {
            let detection = try Self.parseResponse(data)
            logger.info("\(model, privacy: .public) found \(detection.label, privacy: .public) at \(String(describing: detection.box), privacy: .public)")
            return .answer(detection)
        } catch let error as EchoraError {
            return .finalError(error)
        } catch {
            return .finalError(.locatorFailed("Unreadable response"))
        }
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
