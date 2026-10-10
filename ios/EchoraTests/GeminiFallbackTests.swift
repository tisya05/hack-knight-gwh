import XCTest
import simd
@testable import Echora

/// Fake network: answers per model name, records which models were asked.
private final class StubURLProtocol: URLProtocol {
    enum Reply {
        case http(Int, String)
        case timeout
    }

    static var replies: [String: Reply] = [:]
    static var requestedModels: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let model = Self.replies.keys.first { path.contains("/\($0):") } ?? "unknown"
        Self.requestedModels.append(model)

        guard let reply = Self.replies[model], let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch reply {
        case .timeout:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .http(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
    }
}

final class GeminiFallbackTests: XCTestCase {
    private let primary = "model-a"
    private let backup = "model-b"

    private let foundBody = #"{"candidates":[{"content":{"parts":[{"text":"{\"found\":true,\"label\":\"mug\",\"box_2d\":[100,200,300,400]}"}]}}]}"#
    private let notFoundBody = #"{"candidates":[{"content":{"parts":[{"text":"{\"found\":false,\"label\":\"mug\",\"box_2d\":[],\"reason\":\"not visible\"}"}]}}]}"#

    private func makeLocator() -> GeminiLocator {
        GeminiLocator(
            apiKey: "test-key",
            models: [primary, backup],
            attemptTimeouts: [4, 8],
            protocolClasses: [StubURLProtocol.self]
        )
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: Data([0xFF, 0xD8]),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3,
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: .portrait,
            depth: nil
        )
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.replies = [:]
        StubURLProtocol.requestedModels = []
    }

    func testHealthyPrimaryIsTheOnlyCall() async throws {
        StubURLProtocol.replies = [primary: .http(200, foundBody), backup: .http(200, foundBody)]

        let detection = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())

        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary])
    }

    func testOverloadedPrimaryFallsBack() async throws {
        StubURLProtocol.replies = [primary: .http(503, "{}"), backup: .http(200, foundBody)]

        let detection = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())

        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary, backup])
    }

    func testSlowPrimaryFallsBack() async throws {
        StubURLProtocol.replies = [primary: .timeout, backup: .http(200, foundBody)]

        let detection = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())

        XCTAssertEqual(detection.box.minX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary, backup])
    }

    func testRateLimitedPrimaryFallsBack() async throws {
        StubURLProtocol.replies = [primary: .http(429, "{}"), backup: .http(200, foundBody)]

        _ = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())

        XCTAssertEqual(StubURLProtocol.requestedModels, [primary, backup])
    }

    func testNotFoundDoesNotFallBack() async {
        StubURLProtocol.replies = [primary: .http(200, notFoundBody), backup: .http(200, foundBody)]

        do {
            _ = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())
            XCTFail("expected objectNotFound")
        } catch {
            XCTAssertEqual(error as? EchoraError, .objectNotFound("not visible"))
        }
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary])
    }

    func testBadRequestDoesNotFallBack() async {
        StubURLProtocol.replies = [primary: .http(400, #"{"error":{"message":"bad"}}"#), backup: .http(200, foundBody)]

        do {
            _ = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())
            XCTFail("expected locatorFailed")
        } catch {
            XCTAssertEqual(error as? EchoraError, .locatorFailed("HTTP 400: bad"))
        }
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary])
    }

    func testBothSlowReportsTimeout() async {
        StubURLProtocol.replies = [primary: .timeout, backup: .timeout]

        do {
            _ = try await makeLocator().locate(utterance: "mug", in: makeSnapshot())
            XCTFail("expected locatorTimeout")
        } catch {
            XCTAssertEqual(error as? EchoraError, .locatorTimeout)
        }
        XCTAssertEqual(StubURLProtocol.requestedModels, [primary, backup])
    }
}
