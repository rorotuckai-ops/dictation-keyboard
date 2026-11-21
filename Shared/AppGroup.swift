import Foundation

enum AppGroup {
    static let identifier: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "group.dev.rorotuck.dictkb"

    static var container: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        // Unsigned simulator builds without the group still work against a temp folder.
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("AppGroupFallback")
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }

    static func directory(_ name: String) -> URL {
        let url = container.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum SharedKeys {
    static let rewriteMode = "rewriteMode"
    static let hostHeartbeat = "hostHeartbeat"
    static let modelReady = "modelReady"
    static let modelName = "modelName"
    static let useModelForCorrections = "useModelForCorrections"
}
