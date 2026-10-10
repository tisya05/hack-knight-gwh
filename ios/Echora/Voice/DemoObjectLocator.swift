import Foundation
import os

/// `ObjectLocator` for demos without Gemini: every object of `DemoObjectCatalog`
/// has a fixed spot in the camera frame. No network, answers at once.
/// Throws `.objectNotFound` for anything outside the fixed set.
final class DemoObjectLocator: ObjectLocator {
    /// Name to add to `ECHORA_REAL_SERVICES` (Local.xcconfig) to turn this on.
    static let serviceName = "demoobjects"
    /// UserDefaults override, e.g. launch argument `-flag.demoObjects YES`.
    static let defaultsKey = "flag.demoObjects"

    private let logger = Logger(subsystem: "com.gwh.echora", category: "DemoLocator")

    static func isEnabled(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> Bool {
        var override: Bool?
        if defaults.object(forKey: defaultsKey) != nil {
            override = defaults.bool(forKey: defaultsKey)
        }
        let realServices = bundle.object(forInfoDictionaryKey: "ECHORA_REAL_SERVICES") as? String
        return isEnabled(realServices: realServices ?? "", override: override)
    }

    /// `realServices` is space or comma separated, case-insensitive (same rule as ServiceFlags).
    static func isEnabled(realServices: String, override: Bool?) -> Bool {
        if let override {
            return override
        }
        let separators = CharacterSet(charactersIn: " ,")
        let names = realServices.lowercased().components(separatedBy: separators)
        return names.contains(serviceName)
    }

    // MARK: - ObjectLocator

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        guard let object = DemoObjectCatalog.resolve(utterance) else {
            logger.info("\"\(utterance, privacy: .public)\" is not a demo object")
            throw EchoraError.objectNotFound(utterance)
        }
        logger.info("\"\(utterance, privacy: .public)\" -> \(object.name, privacy: .public) at its fixed spot")
        return Detection(label: object.name, box: object.box, confidence: 1.0)
    }
}
