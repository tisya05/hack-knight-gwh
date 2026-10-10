import Foundation

/// One object of the fixed demo set and the spot in the camera frame it stands for.
struct DemoObject: Equatable {
    /// Canonical name. This is what the voice agent hands to the app.
    let name: String
    /// Single lowercase words that also mean this object ("cup" for the mug).
    let aliases: [String]
    /// Upright normalized image space (CONTRACT 2.3).
    let box: NormalizedRect
}

/// The fixed set of objects for demos without Gemini. Each object owns a fixed
/// spot in the camera frame; the normal placement path (LiDAR / raycast) turns
/// that spot into a world position on whatever surface is really there.
///
/// Layout as the camera sees the table (phone held upright):
/// ```
///   mug            bottle
///          keys
///   wallet         glasses
/// ```
/// Keep the names in sync with `scripts/setup_elevenlabs_agent.py`.
enum DemoObjectCatalog {
    private static let boxHalfSize = 0.08

    static let objects: [DemoObject] = [
        makeObject(name: "mug", aliases: ["cup", "coffee", "tea"], centerX: 0.25, centerY: 0.45),
        makeObject(name: "bottle", aliases: ["water", "flask"], centerX: 0.75, centerY: 0.45),
        makeObject(name: "keys", aliases: ["key", "keychain"], centerX: 0.50, centerY: 0.60),
        makeObject(name: "wallet", aliases: ["purse", "cards"], centerX: 0.25, centerY: 0.75),
        makeObject(name: "glasses", aliases: ["sunglasses", "spectacles", "shades"], centerX: 0.75, centerY: 0.75)
    ]

    static var names: [String] {
        var result: [String] = []
        for object in objects {
            result.append(object.name)
        }
        return result
    }

    /// Finds the demo object mentioned in `text` ("where's my cup" -> mug).
    /// Whole words only, so "keyboard" does not match "key". nil when none is mentioned.
    static func resolve(_ text: String) -> DemoObject? {
        let words = Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        for object in objects {
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
        centerX: Double,
        centerY: Double
    ) -> DemoObject {
        let box = NormalizedRect(
            minX: centerX - boxHalfSize,
            minY: centerY - boxHalfSize,
            maxX: centerX + boxHalfSize,
            maxY: centerY + boxHalfSize
        )
        return DemoObject(name: name, aliases: aliases, box: box)
    }
}
