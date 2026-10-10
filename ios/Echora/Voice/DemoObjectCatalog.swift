import Foundation
import simd

/// One object of the fixed demo set and where it sits in the room.
struct DemoObject: Equatable {
    /// Canonical name. This is what the voice agent hands to the app.
    let name: String
    /// Single lowercase words that also mean this object ("cup" for the mug).
    let aliases: [String]
    /// ARKit world space, meters (CONTRACT 2.3). The origin is where the phone was
    /// when the app started, -Z is the way it faced, +X is to its right, +Y is up.
    let worldPosition: SIMD3<Float>
}

/// The fixed set of objects for demos without Gemini. Each object sits at a fixed
/// place in the room, so it can be in or out of the camera's view like a real one.
///
/// Seen from above, with the phone at the bottom facing up the page when the app starts:
/// ```
///   mug            bottle       0.60 m ahead
///          keys                 0.50 m
///   wallet         glasses      0.40 m
///         (phone)               all 0.30 m below the phone, 0.18 m to each side
/// ```
/// The spacing fits what the camera sees when the phone is held upright at chest
/// height and tilted down at the table (DemoObjectCatalogTests checks this).
/// Keep the names in sync with `scripts/setup_elevenlabs_agent.py`.
enum DemoObjectCatalog {
    private static let tableBelowPhoneMeters: Float = 0.30

    static let objects: [DemoObject] = [
        makeObject(name: "mug", aliases: ["cup", "coffee", "tea"], right: -0.18, ahead: 0.60),
        makeObject(name: "bottle", aliases: ["water", "flask"], right: 0.18, ahead: 0.60),
        makeObject(name: "keys", aliases: ["key", "keychain"], right: 0.0, ahead: 0.50),
        makeObject(name: "wallet", aliases: ["purse", "cards"], right: -0.18, ahead: 0.40),
        makeObject(name: "glasses", aliases: ["sunglasses", "spectacles", "shades"], right: 0.18, ahead: 0.40)
    ]

    static var names: [String] {
        var result: [String] = []
        for object in objects {
            result.append(object.name)
        }
        return result
    }

    /// Finds the object mentioned in `text` ("where's my cup" -> mug).
    /// Whole words only, so "keyboard" does not match "key". nil when none is mentioned.
    static func resolve(_ text: String, in candidates: [DemoObject] = objects) -> DemoObject? {
        let words = Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        for object in candidates {
            if words.contains(object.name) {
                return object
            }
            for alias in object.aliases {
                if words.contains(alias) {
                    return object
                }
            }
        }
        return nil
    }

    private static func makeObject(
        name: String,
        aliases: [String],
        right: Float,
        ahead: Float
    ) -> DemoObject {
        let position = SIMD3<Float>(right, -tableBelowPhoneMeters, -ahead)
        return DemoObject(name: name, aliases: aliases, worldPosition: position)
    }
}

/// Where a world point shows up in a saved snapshot: the inverse of `RayMath.ray(through:snapshot:)`.
/// Pure math, unit tested against RayMath so the two cannot drift apart.
enum DemoObjectProjection {
    /// Points closer to the edge than this count as out of view.
    static let frameMargin = 0.05
    /// Half the side of the box reported around a visible object.
    static let boxHalfSize = 0.08
    private static let minimumDepthMeters: Float = 0.05

    /// Upright normalized image point (CONTRACT 2.3) of `worldPoint`. It can lie
    /// outside 0...1 when the point is off screen. nil when it is behind the camera.
    static func uprightPoint(of worldPoint: SIMD3<Float>, in snapshot: Snapshot) -> NormalizedPoint? {
        let worldToCamera = snapshot.cameraTransform.inverse
        let inCamera = worldToCamera * SIMD4<Float>(worldPoint, 1)
        // The camera looks down -Z.
        let depth = -inCamera.z
        guard depth > minimumDepthMeters else {
            return nil
        }

        let intrinsics = snapshot.intrinsics
        let focalX = intrinsics[0][0]
        let focalY = intrinsics[1][1]
        let centerX = intrinsics[2][0]
        let centerY = intrinsics[2][1]
        let width = Float(snapshot.sensorResolution.width)
        let height = Float(snapshot.sensorResolution.height)
        guard width > 0, height > 0 else {
            return nil
        }

        // Image y points down, camera y points up.
        let pixelX = centerX + focalX * (inCamera.x / depth)
        let pixelY = centerY - focalY * (inCamera.y / depth)
        let sensorX = Double(pixelX / width)
        let sensorY = Double(pixelY / height)

        // Inverse of ImageSpace.sensorNormalized(fromUpright:rotation:).
        switch snapshot.uprightRotation {
        case .portrait:
            return NormalizedPoint(x: 1.0 - sensorY, y: sensorX)
        case .landscapeRight:
            return NormalizedPoint(x: sensorX, y: sensorY)
        }
    }

    /// The object's box in the snapshot, or nil when the camera is not looking at it.
    static func visibleBox(of worldPoint: SIMD3<Float>, in snapshot: Snapshot) -> NormalizedRect? {
        guard let point = uprightPoint(of: worldPoint, in: snapshot) else {
            return nil
        }
        let visibleRange = frameMargin...(1.0 - frameMargin)
        guard visibleRange.contains(point.x), visibleRange.contains(point.y) else {
            return nil
        }
        return NormalizedRect(
            minX: max(point.x - boxHalfSize, 0),
            minY: max(point.y - boxHalfSize, 0),
            maxX: min(point.x + boxHalfSize, 1),
            maxY: min(point.y + boxHalfSize, 1)
        )
    }
}
