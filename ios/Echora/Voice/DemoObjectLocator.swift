import Foundation
import os

/// `ObjectLocator` for demos without Gemini: every object of `DemoObjectCatalog`
/// sits at a fixed place in the room. No network, answers at once.
///
/// Like a real detector it only finds what the camera is looking at: when the
/// object's place is outside the snapshot (the phone points somewhere else) it
/// throws `.objectNotFound`, same as for a name outside the fixed set.
final class DemoObjectLocator: ObjectLocator {
    /// Name to add to `ECHORA_REAL_SERVICES` (Local.xcconfig) to turn this on.
    static let serviceName = "demoobjects"
    /// UserDefaults override, e.g. launch argument `-flag.demoObjects YES`.
    static let defaultsKey = "flag.demoObjects"

    private let objects: [DemoObject]
    private let logger = Logger(subsystem: "com.gwh.echora", category: "DemoLocator")

    init(objects: [DemoObject] = DemoObjectCatalog.objects) {
        self.objects = objects
    }

    static func isEnabled(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> Bool {
        return VoiceFeatureFlags.isOn(serviceName, defaultsKey: defaultsKey, defaults: defaults, bundle: bundle)
    }

    // MARK: - ObjectLocator

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        guard let object = DemoObjectCatalog.resolve(utterance, in: objects) else {
            logger.info("\"\(utterance, privacy: .public)\" is not a demo object")
            throw EchoraError.objectNotFound(utterance)
        }
        guard let box = DemoObjectProjection.visibleBox(of: object.worldPosition, in: snapshot) else {
            logger.info("\(object.name, privacy: .public) is not in the camera's view")
            throw EchoraError.objectNotFound(object.name)
        }
        logger.info("\(object.name, privacy: .public) in view at \(box.center.x, privacy: .public), \(box.center.y, privacy: .public)")
        return Detection(label: object.name, box: box, confidence: 1.0)
    }
}
