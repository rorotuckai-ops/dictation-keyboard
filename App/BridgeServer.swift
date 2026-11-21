import AVFoundation
import Foundation
import Observation

/// Serves the keyboard's requests from the App Group. While "Stay ready in background" is on,
/// a silent audio loop keeps the app (and the loaded Gemma model) alive after you switch back
/// to the app you're typing in, so Fix works without leaving that app.
@MainActor
@Observable
final class BridgeServer {
    static let shared = BridgeServer()

    private(set) var lastResult: String?
    private(set) var busy = false
    private(set) var returnHint = false
    var stayReady: Bool = UserDefaults.standard.object(forKey: "stayReady") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(stayReady, forKey: "stayReady")
            stayReady ? keeper.start() : keeper.stop()
        }
    }

    private let keeper = BackgroundKeeper()
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Bridge.observe(Bridge.requestNotification) {
            Task { @MainActor in BridgeServer.shared.drain() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                AppGroup.defaults.set(Date().timeIntervalSince1970, forKey: SharedKeys.hostHeartbeat)
                BridgeServer.shared.drain()
            }
        }
        if stayReady { keeper.start() }
        Task {
            await ModelService.shared.loadIfPossible()
            drain()
        }
    }

    func handleOpen(_ url: URL) {
        returnHint = url.host == "process"
        start()
        drain()
    }

    func drain() {
        guard !busy else { return }
        guard let request = Bridge.pendingRequests().first else { return }
        // Stale requests (keyboard gave up) are dropped.
        if Date().timeIntervalSince(request.created) > 600 {
            Bridge.cancel(request.id)
            return drain()
        }
        busy = true
        Task {
            let started = Date()
            var response = BridgeResponse(id: request.id, text: nil, error: nil, seconds: 0)
            do {
                if request.task == .transcribe {
                    response.text = try await Transcriber.transcribe(AppGroup.container.appendingPathComponent(request.text))
                } else {
                    response.text = try await ModelService.shared.run(request.task, text: request.text)
                }
            } catch {
                response.error = error.localizedDescription
            }
            response.seconds = Date().timeIntervalSince(started)
            Bridge.complete(response)
            lastResult = response.text ?? response.error
            busy = false
            drain()
        }
    }
}

/// Plays inaudible silence (mixed with other audio) so iOS keeps the app running in the background.
final class BackgroundKeeper {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try WAVFile.write(samples: Data(count: 16_000 * 2), sampleRate: 16_000, to: url)
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            self.player = player
        } catch {
            NSLog("[DictKB] background keeper failed: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
