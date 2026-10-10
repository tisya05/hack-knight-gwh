import XCTest
@testable import Echora

/// CONTRACT 4.2 fixtures. Shapes copied from real gemini-3.6-flash responses (2026-10-09).
final class GeminiParsingTests: XCTestCase {
    /// Wraps the model's JSON answer in a generateContent envelope.
    private func envelope(answer: String, extraParts: String = "") -> Data {
        let escaped = answer
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {"candidates":[{"content":{"role":"model","parts":[\(extraParts){"text":"\(escaped)"}]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":1290,"candidatesTokenCount":60}}
        """
        return Data(json.utf8)
    }

    private func assertLocatorFailed(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GeminiLocator.parseResponse(data), file: file, line: line) { error in
            guard case EchoraError.locatorFailed = error else {
                XCTFail("expected .locatorFailed, got \(error)", file: file, line: line)
                return
            }
        }
    }

    // MARK: - Fixtures from the contract

    func testFound() throws {
        let answer = #"{"found": true, "label": "blue circle", "box_2d": [410, 430, 590, 569], "confidence": 0.99, "reason": "center"}"#
        let detection = try GeminiLocator.parseResponse(envelope(answer: answer))

        XCTAssertEqual(detection.label, "blue circle")
        XCTAssertEqual(detection.box.minX, 0.430, accuracy: 1e-9)
        XCTAssertEqual(detection.box.minY, 0.410, accuracy: 1e-9)
        XCTAssertEqual(detection.box.maxX, 0.569, accuracy: 1e-9)
        XCTAssertEqual(detection.box.maxY, 0.590, accuracy: 1e-9)
        XCTAssertEqual(detection.confidence ?? 0, 0.99, accuracy: 1e-9)
    }

    func testNotFound() {
        let answer = #"{"found":false,"label":"car keys","box_2d":[],"confidence":0.0,"reason":"The car keys are not present in the image."}"#
        XCTAssertThrowsError(try GeminiLocator.parseResponse(envelope(answer: answer))) { error in
            XCTAssertEqual(error as? EchoraError, .objectNotFound("The car keys are not present in the image."))
        }
    }

    func testMalformedBoxWrongCount() {
        let answer = #"{"found": true, "label": "mug", "box_2d": [410, 430, 590]}"#
        assertLocatorFailed(envelope(answer: answer))
    }

    func testBoxValuesOver1000() {
        let answer = #"{"found": true, "label": "mug", "box_2d": [410, 430, 1200, 569]}"#
        assertLocatorFailed(envelope(answer: answer))
    }

    // MARK: - More edge cases

    func testBoxMinNotBelowMax() {
        let answer = #"{"found": true, "label": "mug", "box_2d": [590, 430, 410, 569]}"#
        assertLocatorFailed(envelope(answer: answer))
    }

    func testFoundWithoutBox() {
        let answer = #"{"found": true, "label": "mug"}"#
        assertLocatorFailed(envelope(answer: answer))
    }

    func testThoughtPartIsSkipped() throws {
        let thought = #"{"text":"thinking about mugs","thought":true},"#
        let answer = #"{"found": true, "label": "mug", "box_2d": [100, 200, 300, 400]}"#
        let detection = try GeminiLocator.parseResponse(envelope(answer: answer, extraParts: thought))
        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(detection.box.minX, 0.2, accuracy: 1e-9)
    }

    func testConfidenceIsClamped() throws {
        let answer = #"{"found": true, "label": "mug", "box_2d": [100, 200, 300, 400], "confidence": 7}"#
        let detection = try GeminiLocator.parseResponse(envelope(answer: answer))
        XCTAssertEqual(detection.confidence, 1)
    }

    func testNoCandidates() {
        assertLocatorFailed(Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8))
    }

    func testAnswerNotJSON() {
        assertLocatorFailed(envelope(answer: "Sure! The mug is on the left."))
    }

    // MARK: - HTTP errors

    func testRateLimitAndOverloadMessages() {
        XCTAssertEqual(
            GeminiLocator.httpError(status: 429, body: Data()),
            .locatorFailed("Gemini rate limit reached, wait a minute")
        )
        XCTAssertEqual(
            GeminiLocator.httpError(status: 503, body: Data()),
            .locatorFailed("Gemini is overloaded, try again")
        )
        let body = Data(#"{"error":{"code":400,"message":"Bad thing"}}"#.utf8)
        XCTAssertEqual(GeminiLocator.httpError(status: 400, body: body), .locatorFailed("HTTP 400: Bad thing"))
    }

    // MARK: - Request body

    func testRequestBodyMatchesContract() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        let data = try GeminiLocator.requestBody(utterance: "where's my mug", jpeg: jpeg, thinkingLevel: "minimal")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let inline = try XCTUnwrap(parts.first?["inline_data"] as? [String: Any])
        XCTAssertEqual(inline["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(inline["data"] as? String, jpeg.base64EncodedString())

        let text = try XCTUnwrap(parts.last?["text"] as? String)
        XCTAssertTrue(text.contains("The user said: \"where's my mug\""))
        XCTAssertTrue(text.contains("[ymin, xmin, ymax, xmax]"))

        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["temperature"] as? Int, 0)
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["thinkingLevel"] as? String, "minimal")
    }

    // MARK: - Free-tier guard

    func testRateLimiterAllowsUpToLimitPerWindow() {
        var limiter = RequestRateLimiter(maximumRequests: 3, window: 60)
        let start = Date(timeIntervalSince1970: 1000)

        XCTAssertTrue(limiter.allowRequest(at: start))
        XCTAssertTrue(limiter.allowRequest(at: start.addingTimeInterval(1)))
        XCTAssertTrue(limiter.allowRequest(at: start.addingTimeInterval(2)))
        XCTAssertFalse(limiter.allowRequest(at: start.addingTimeInterval(3)))

        // The first request falls out of the window after 60 s.
        XCTAssertTrue(limiter.allowRequest(at: start.addingTimeInterval(60.5)))
        XCTAssertFalse(limiter.allowRequest(at: start.addingTimeInterval(60.8)))
    }

    func testMissingKeyGivesNoLocator() {
        // The unit-test bundle has no GEMINI_API_KEY.
        XCTAssertNil(GeminiLocator.makeFromBundle(Bundle(for: GeminiParsingTests.self)))
    }
}
