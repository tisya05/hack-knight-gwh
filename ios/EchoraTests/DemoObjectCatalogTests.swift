import XCTest
import simd
@testable import Echora

final class DemoObjectCatalogTests: XCTestCase {
    func testResolvesNameInsideASentence() {
        XCTAssertEqual(DemoObjectCatalog.resolve("Where's my mug?")?.name, "mug")
        XCTAssertEqual(DemoObjectCatalog.resolve("KEYS")?.name, "keys")
    }

    func testResolvesAliases() {
        XCTAssertEqual(DemoObjectCatalog.resolve("find my cup")?.name, "mug")
        XCTAssertEqual(DemoObjectCatalog.resolve("the water bottle")?.name, "bottle")
        XCTAssertEqual(DemoObjectCatalog.resolve("my sunglasses please")?.name, "glasses")
    }

    func testMatchesWholeWordsOnly() {
        XCTAssertNil(DemoObjectCatalog.resolve("keyboard"))
        XCTAssertNil(DemoObjectCatalog.resolve("smug"))
    }

    func testUnknownObjectIsNil() {
        XCTAssertNil(DemoObjectCatalog.resolve("stapler"))
        XCTAssertNil(DemoObjectCatalog.resolve(""))
    }

    func testEveryObjectHasADistinctSpotInsideTheFrame() {
        var centers: [NormalizedPoint] = []
        for object in DemoObjectCatalog.objects {
            let box = object.box
            XCTAssertGreaterThanOrEqual(box.minX, 0, object.name)
            XCTAssertGreaterThanOrEqual(box.minY, 0, object.name)
            XCTAssertLessThanOrEqual(box.maxX, 1, object.name)
            XCTAssertLessThanOrEqual(box.maxY, 1, object.name)
            XCTAssertLessThan(box.minX, box.maxX, object.name)
            XCTAssertLessThan(box.minY, box.maxY, object.name)
            XCTAssertFalse(centers.contains(box.center), "\(object.name) shares a spot")
            centers.append(box.center)
        }
    }

    /// The coordinator checks "found" and "calibrate" keywords before it treats a
    /// transcript as an object, so no object name may trip them.
    func testObjectNamesAreNotVoiceCommands() {
        for name in DemoObjectCatalog.names {
            XCTAssertFalse(EchoraCoordinator.isFoundCommand(name), name)
            XCTAssertFalse(EchoraCoordinator.isCalibrateCommand(name), name)
        }
    }

    // MARK: - Locator

    func testLocatorReturnsTheFixedBox() async throws {
        let locator = DemoObjectLocator()
        let detection = try await locator.locate(utterance: "where is my cup", in: Self.makeSnapshot())
        let mug = try XCTUnwrap(DemoObjectCatalog.resolve("mug"))

        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(detection.box, mug.box)
    }

    func testLocatorThrowsNotFoundOutsideTheSet() async {
        let locator = DemoObjectLocator()
        do {
            _ = try await locator.locate(utterance: "stapler", in: Self.makeSnapshot())
            XCTFail("Expected objectNotFound")
        } catch {
            XCTAssertEqual(error as? EchoraError, .objectNotFound("stapler"))
        }
    }

    func testEnabledByRealServicesName() {
        XCTAssertTrue(DemoObjectLocator.isEnabled(realServices: "perception audio demoObjects", override: nil))
        XCTAssertTrue(DemoObjectLocator.isEnabled(realServices: "voice,DEMOOBJECTS", override: nil))
        XCTAssertFalse(DemoObjectLocator.isEnabled(realServices: "perception audio", override: nil))
        XCTAssertFalse(DemoObjectLocator.isEnabled(realServices: "", override: nil))
    }

    func testUserDefaultsOverrideWins() {
        XCTAssertFalse(DemoObjectLocator.isEnabled(realServices: "demoObjects", override: false))
        XCTAssertTrue(DemoObjectLocator.isEnabled(realServices: "", override: true))
    }

    private static func makeSnapshot() -> Snapshot {
        return Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: Data(),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3,
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: .portrait,
            depth: nil
        )
    }
}
