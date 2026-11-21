import Foundation
import LiteRTLM
import Observation

/// Runs a Gemma `.litertlm` model fully offline with LiteRT-LM.
@MainActor
@Observable
final class ModelService {
    static let shared = ModelService()

    enum Status: Equatable {
        case missing
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    static let downloadURL = URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!

    private(set) var status: Status = .missing
    private(set) var modelURL: URL?
    private var engine: Engine?
    private var download: ModelDownload?

    static var modelsDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return url
    }

    private init() {
        modelURL = Self.findModel()
    }

    static func findModel() -> URL? {
        let fm = FileManager.default
        let documents = (try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        if let found = documents.filter({ $0.pathExtension == "litertlm" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            return found
        }
        if let bundled = Bundle.main.url(forResource: "gemma-4-E2B-it", withExtension: "litertlm") { return bundled }
        return nil
    }

    var modelName: String { modelURL?.deletingPathExtension().lastPathComponent ?? "No model" }

    func loadIfPossible() async {
        if engine != nil { return }
        if case .downloading = status { return }
        modelURL = Self.findModel()
        guard let modelURL else {
            status = .missing
            AppGroup.defaults.set(false, forKey: SharedKeys.modelReady)
            return
        }
        status = .loading
        do {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("litertlm", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            #if targetEnvironment(simulator)
            let backend: Backend = .cpu()
            #else
            let backend: Backend = .gpu
            #endif
            let config = try EngineConfig(modelPath: modelURL.path, backend: backend, maxNumTokens: 2048, cacheDir: cache.path)
            let engine = Engine(engineConfig: config)
            try await engine.initialize()
            self.engine = engine
            status = .ready
            AppGroup.defaults.set(true, forKey: SharedKeys.modelReady)
            AppGroup.defaults.set(modelName, forKey: SharedKeys.modelName)
        } catch {
            status = .failed(error.localizedDescription)
            AppGroup.defaults.set(false, forKey: SharedKeys.modelReady)
        }
    }

    /// Runs one task in a fresh conversation so earlier requests never leak into the next.
    func run(_ task: BridgeTask, text: String) async throws -> String {
        if engine == nil { await loadIfPossible() }
        guard let engine else {
            throw NSError(domain: "DictKB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gemma isn't loaded. Open the app to add the model."])
        }
        let conversation = try await engine.createConversation()
        let reply = try await conversation.sendMessage(
            Message(Prompts.prompt(for: task, text: text)),
            maxOutputTokens: max(256, text.count / 2 + 128))
        let output = Prompts.clean(reply.toString)
        guard !output.isEmpty else {
            throw NSError(domain: "DictKB", code: 2, userInfo: [NSLocalizedDescriptionKey: "Gemma returned nothing"])
        }
        return output
    }

    func startDownload() {
        let download = ModelDownload(from: Self.downloadURL, to: Self.modelsDirectory.appendingPathComponent("gemma-4-E2B-it.litertlm"))
        self.download = download
        status = .downloading(0)
        download.onProgress = { [weak self] p in Task { @MainActor in self?.status = .downloading(p) } }
        download.onFinish = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.download = nil
                if let error { self.status = .failed(error.localizedDescription) } else { await self.loadIfPossible() }
            }
        }
        download.start()
    }

    func importModel(from url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let destination = Self.modelsDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            if url.standardizedFileURL != destination.standardizedFileURL {
                for old in (try? FileManager.default.contentsOfDirectory(at: Self.modelsDirectory, includingPropertiesForKeys: nil)) ?? []
                where old.pathExtension == "litertlm" { try? FileManager.default.removeItem(at: old) }
                try FileManager.default.copyItem(at: url, to: destination)
            }
            engine = nil
            await loadIfPossible()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((Double) -> Void)?
    var onFinish: ((Error?) -> Void)?
    private let source: URL
    private let destination: URL
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(from source: URL, to destination: URL) {
        self.source = source
        self.destination = destination
    }

    func start() { session.downloadTask(with: source).resume() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onFinish?(nil)
        } catch {
            onFinish?(error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onFinish?(error) }
    }
}
