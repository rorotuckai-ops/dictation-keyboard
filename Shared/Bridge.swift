import Foundation

/// File-based request/response channel between the keyboard and the host app, inside the App Group.
/// The keyboard writes a request and posts a Darwin notification; the host app (kept alive in the
/// background, or opened through the `dictkb://` URL) runs Gemma and writes the response.
enum BridgeTask: String, Codable, Sendable {
    case fix
    case rewrite
    case correct
    /// `text` is a clip's path inside the App Group; the host transcribes it.
    case transcribe
}

struct BridgeRequest: Codable, Sendable, Equatable {
    var id: UUID
    var task: BridgeTask
    var text: String
    var created: Date
}

struct BridgeResponse: Codable, Sendable, Equatable {
    var id: UUID
    var text: String?
    var error: String?
    var seconds: Double
}

enum Bridge {
    static let requestNotification = "dev.dictkb.bridge.request"
    static let responseNotification = "dev.dictkb.bridge.response"

    static var requests: URL { AppGroup.directory("requests") }
    static var responses: URL { AppGroup.directory("responses") }

    static func submit(_ request: BridgeRequest) throws {
        let data = try JSONEncoder().encode(request)
        try data.write(to: requests.appendingPathComponent("\(request.id.uuidString).json"), options: .atomic)
        post(requestNotification)
    }

    static func pendingRequests() -> [BridgeRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(BridgeRequest.self, from: data)
        }
        .sorted { $0.created < $1.created }
    }

    static func complete(_ response: BridgeResponse) {
        if let data = try? JSONEncoder().encode(response) {
            try? data.write(to: responses.appendingPathComponent("\(response.id.uuidString).json"), options: .atomic)
        }
        try? FileManager.default.removeItem(at: requests.appendingPathComponent("\(response.id.uuidString).json"))
        post(responseNotification)
    }

    /// Reads and removes the response for `id`, if the host has written it.
    static func takeResponse(_ id: UUID) -> BridgeResponse? {
        let url = responses.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(BridgeResponse.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return response
    }

    static func cancel(_ id: UUID) {
        try? FileManager.default.removeItem(at: requests.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: responses.appendingPathComponent("\(id.uuidString).json"))
    }

    /// The host writes a heartbeat every second while it can serve requests in the background.
    static var hostIsRunning: Bool {
        Date().timeIntervalSince1970 - AppGroup.defaults.double(forKey: SharedKeys.hostHeartbeat) < 3
    }

    /// The host is running and has Gemma loaded.
    static var hostIsAlive: Bool {
        hostIsRunning && AppGroup.defaults.bool(forKey: SharedKeys.modelReady)
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    static func observe(_ name: String, _ handler: @escaping @Sendable () -> Void) {
        DarwinObservers.shared.add(name, handler)
    }
}

final class DarwinObservers: @unchecked Sendable {
    static let shared = DarwinObservers()
    private var handlers: [String: [@Sendable () -> Void]] = [:]
    private let lock = NSLock()

    func add(_ name: String, _ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let first = handlers[name] == nil
        handlers[name, default: []].append(handler)
        lock.unlock()
        guard first else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let me = Unmanaged<DarwinObservers>.fromOpaque(observer).takeUnretainedValue()
                me.fire(name.rawValue as String)
            },
            name as CFString, nil, .deliverImmediately)
    }

    private func fire(_ name: String) {
        lock.lock()
        let list = handlers[name] ?? []
        lock.unlock()
        list.forEach { $0() }
    }
}
