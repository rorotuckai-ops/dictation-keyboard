import Foundation

/// Dictation recorded in the app, waiting for the keyboard's Insert. Expires so a stale
/// result is never inserted silently.
struct PendingDictation: Codable, Equatable {
    static let lifetime: TimeInterval = 15 * 60

    var id = UUID()
    var text: String
    var heard: String
    var changes: [CorrectionChange]
    var created = Date()

    var expired: Bool { Date().timeIntervalSince(created) > Self.lifetime }

    static var current: PendingDictation? {
        get {
            guard let data = AppGroup.defaults.data(forKey: SharedKeys.pendingDictation),
                  let value = try? JSONDecoder().decode(PendingDictation.self, from: data) else { return nil }
            return value
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                AppGroup.defaults.set(data, forKey: SharedKeys.pendingDictation)
            } else {
                AppGroup.defaults.removeObject(forKey: SharedKeys.pendingDictation)
            }
        }
    }
}

#if DEBUG
/// Test hooks for the simulator, which has no microphone and can't run speech recognition:
/// `<App Group>/fixtures/dictation.txt` stands in for the recognizer's output and
/// `fixtures/dictation.wav` for the mic. The rest of the pipeline runs as normal.
enum DebugFixture {
    static var audio: URL? { file("fixtures/dictation.wav") }
    static var transcript: URL? { file("fixtures/dictation.txt") }

    static var transcriptText: String? {
        if let arg = ProcessInfo.processInfo.environment["DICTKB_TRANSCRIPT"] { return arg }
        guard let url = transcript else { return nil }
        return try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func file(_ path: String) -> URL? {
        let url = AppGroup.container.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif
