import XCTest
import simd
@testable import Echora

final class DemoObjectCatalogTests: XCTestCase {

    // MARK: - Names

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

    /// The coordinator checks "found" and "calibrate" keywords before it treats a
    /// transcript as an object, so no object name may trip them.
    func testObjectNamesAreNotVoiceCommands() {
        for name in DemoObjectCatalog.names {
            XCTAssertFalse(EchoraCoordinator.isFoundCommand(name), name)
            XCTAssertFalse(EchoraCoordinator.isCalibrateCommand(name), name)
        }
    }

    // MARK: - Projection

    func testPointStraightAheadIsTheImageCenter() throws {
        let snapshot = Self.makeSnapshot(transform: matrix_identity_float4x4, rotation: .landscapeRight)
        let projected = DemoObjectProjection.uprightPoint(of: SIMD3<Float>(0, 0, -1), in: snapshot)
        let point = try XCTUnwrap(projected)

        XCTAssertEqual(point.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(point.y, 0.5, accuracy: 1e-5)
    }

    func testRightIsRightAndUpIsUpInTheSensorImage() throws {
        let snapshot = Self.makeSnapshot(transform: matrix_identity_float4x4, rotation: .landscapeRight)
        let right = try XCTUnwrap(DemoObjectProjection.uprightPoint(of: SIMD3<Float>(0.2, 0, -1), in: snapshot))
        let above = try XCTUnwrap(DemoObjectProjection.uprightPoint(of: SIMD3<Float>(0, 0.2, -1), in: snapshot))

        XCTAssertGreaterThan(right.x, 0.5)
        XCTAssertEqual(right.y, 0.5, accuracy: 1e-5)
        XCTAssertLessThan(above.y, 0.5)
    }

    func testPointBehindTheCameraIsNil() {
        let snapshot = Self.makeSnapshot(transform: matrix_identity_float4x4, rotation: .portrait)
        XCTAssertNil(DemoObjectProjection.uprightPoint(of: SIMD3<Float>(0, 0, 1), in: snapshot))
        XCTAssertNil(DemoObjectProjection.visibleBox(of: SIMD3<Float>(0, 0, 1), in: snapshot))
    }

    /// Projection must be the exact inverse of the ray Tisya's placement shoots through the box.
    func testProjectionIsTheInverseOfRayMath() throws {
        let snapshot = Self.makeSnapshot(transform: Self.heldPhone(yawDegrees: 20, tiltDownDegrees: 35))
        let origin = SIMD3<Float>(0.1, 0.05, 0.2)

        for object in DemoObjectCatalog.objects {
            let projected = DemoObjectProjection.uprightPoint(of: object.worldPosition, in: snapshot)
            let point = try XCTUnwrap(projected, object.name)
            let ray = RayMath.ray(through: point, snapshot: snapshot)
            let expected = simd_normalize(object.worldPosition - origin)

            XCTAssertGreaterThan(simd_dot(ray.direction, expected), 0.9999, object.name)
        }
    }

    // MARK: - What the camera sees

    func testPhoneAtChestLookingAtTheTableSeesEveryObject() throws {
        let tilts: [Float] = [25, 35, 45]
        for tilt in tilts {
            let transform = Self.heldPhone(yawDegrees: 0, tiltDownDegrees: tilt, position: .zero)
            let snapshot = Self.makeSnapshot(transform: transform)
            for object in DemoObjectCatalog.objects {
                let box = DemoObjectProjection.visibleBox(of: object.worldPosition, in: snapshot)
                XCTAssertNotNil(box, "\(object.name) at \(tilt) degrees")
            }
        }
    }

    func testLayoutLooksTheSameInTheImageAsOnTheTable() throws {
        let transform = Self.heldPhone(yawDegrees: 0, tiltDownDegrees: 35, position: .zero)
        let snapshot = Self.makeSnapshot(transform: transform)
        let mug = try Self.center(of: "mug", in: snapshot)
        let bottle = try Self.center(of: "bottle", in: snapshot)
        let wallet = try Self.center(of: "wallet", in: snapshot)

        // Mug is left of the bottle, and farther away than the wallet (higher in the image).
        XCTAssertLessThan(mug.x, bottle.x)
        XCTAssertLessThan(mug.y, wallet.y)
    }

    func testTurningAwayLosesEveryObject() {
        let turns: [Float] = [90, 180, -90]
        for turn in turns {
            let transform = Self.heldPhone(yawDegrees: turn, tiltDownDegrees: 35, position: .zero)
            let snapshot = Self.makeSnapshot(transform: transform)
            for object in DemoObjectCatalog.objects {
                let box = DemoObjectProjection.visibleBox(of: object.worldPosition, in: snapshot)
                XCTAssertNil(box, "\(object.name) after turning \(turn) degrees")
            }
        }
    }

    // MARK: - Locator

    func testLocatorFindsAnObjectInView() async throws {
        let transform = Self.heldPhone(yawDegrees: 0, tiltDownDegrees: 35, position: .zero)
        let snapshot = Self.makeSnapshot(transform: transform)
        let detection = try await DemoObjectLocator().locate(utterance: "where is my cup", in: snapshot)
        let expectedCenter = try Self.center(of: "mug", in: snapshot)

        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(detection.box.center.x, expectedCenter.x, accuracy: 1e-6)
        XCTAssertEqual(detection.box.center.y, expectedCenter.y, accuracy: 1e-6)
    }

    func testLocatorThrowsNotFoundWhenFacingAway() async {
        let transform = Self.heldPhone(yawDegrees: 120, tiltDownDegrees: 35, position: .zero)
        let snapshot = Self.makeSnapshot(transform: transform)
        do {
            _ = try await DemoObjectLocator().locate(utterance: "my mug", in: snapshot)
            XCTFail("Expected objectNotFound")
        } catch {
            XCTAssertEqual(error as? EchoraError, .objectNotFound("mug"))
        }
    }

    func testLocatorThrowsNotFoundOutsideTheSet() async {
        let transform = Self.heldPhone(yawDegrees: 0, tiltDownDegrees: 35, position: .zero)
        let snapshot = Self.makeSnapshot(transform: transform)
        do {
            _ = try await DemoObjectLocator().locate(utterance: "stapler", in: snapshot)
            XCTFail("Expected objectNotFound")
        } catch {
            XCTAssertEqual(error as? EchoraError, .objectNotFound("stapler"))
        }
    }

    // MARK: - Switches

    func testSwitchedOnByRealServicesName() {
        let name = DemoObjectLocator.serviceName
        XCTAssertTrue(VoiceFeatureFlags.isOn(name, realServices: "perception audio demoObjects", override: nil))
        XCTAssertTrue(VoiceFeatureFlags.isOn(name, realServices: "voice,DEMOOBJECTS", override: nil))
        XCTAssertFalse(VoiceFeatureFlags.isOn(name, realServices: "perception audio", override: nil))
        XCTAssertFalse(VoiceFeatureFlags.isOn(name, realServices: "", override: nil))
    }

    func testUserDefaultsOverrideWins() {
        let name = AnnouncingLocator.serviceName
        XCTAssertFalse(VoiceFeatureFlags.isOn(name, realServices: "announcements", override: false))
        XCTAssertTrue(VoiceFeatureFlags.isOn(name, realServices: "", override: true))
    }

    // MARK: - Helpers

    private static func center(of name: String, in snapshot: Snapshot) throws -> NormalizedPoint {
        let object = try XCTUnwrap(DemoObjectCatalog.resolve(name))
        let box = try XCTUnwrap(DemoObjectProjection.visibleBox(of: object.worldPosition, in: snapshot), name)
        return box.center
    }

    /// ARKit camera transform of a phone held upright (portrait), turned `yawDegrees`
    /// to the LEFT and tilted down at the table.
    /// Camera axes on a portrait phone: +x runs down the screen, +y to the user's
    /// right, +z out of the screen toward the user.
    static func heldPhone(
        yawDegrees: Float,
        tiltDownDegrees: Float,
        position: SIMD3<Float> = SIMD3<Float>(0.1, 0.05, 0.2)
    ) -> simd_float4x4 {
        let portrait = simd_float4x4(
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let tilt = simd_float4x4(simd_quatf(angle: -tiltDownDegrees * .pi / 180, axis: SIMD3<Float>(1, 0, 0)))
        let yaw = simd_float4x4(simd_quatf(angle: yawDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))

        var transform = yaw * tilt * portrait
        transform.columns.3 = SIMD4<Float>(position, 1)
        return transform
    }

    static func makeSnapshot(
        transform: simd_float4x4,
        rotation: UprightRotation = .portrait
    ) -> Snapshot {
        // Plausible iPhone wide-camera intrinsics for a 1920 x 1440 sensor image.
        let intrinsics = simd_float3x3(
            SIMD3<Float>(1500, 0, 0),
            SIMD3<Float>(0, 1500, 0),
            SIMD3<Float>(960, 720, 1)
        )
        return Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: Data(),
            cameraTransform: transform,
            intrinsics: intrinsics,
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: rotation,
            depth: nil
        )
    }
}
