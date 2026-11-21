import AVFoundation
import Observation
import SwiftUI

/// Records in the app, transcribes and applies spoken corrections, then leaves the
/// result in the App Group for the keyboard's Insert.
@MainActor @Observable
final class HostDictation {
    enum Phase: Equatable {
        case idle
        case recording
        case processing
        case result(PendingDictation)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var levels: [Float] = []
    private(set) var started = Date()
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    /// Bumped by cancel so a transcription still running is dropped instead of saved.
    private var generation = 0
    private let url = AppGroup.directory("audio").appendingPathComponent("host.wav")

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone.")
            return
        }
        levels = []
        started = Date()
        #if DEBUG
        if DebugFixture.transcriptText != nil { phase = .recording; return }
        #endif
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            phase = .recording
            meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 16, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
        } catch {
            phase = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func sample() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        levels.append(max(0.04, min(1, pow(10, power / 40))))
        if levels.count > 40 { levels.removeFirst(levels.count - 40) }
    }

    func cancel() {
        generation += 1
        stopRecorder()
        phase = .idle
    }

    func stop(model: ModelService) async {
        stopRecorder()
        phase = .processing
        let run = generation
        do {
            let raw: String
            #if DEBUG
            if let fixture = DebugFixture.transcriptText {
                try? await Task.sleep(for: .milliseconds(600))
                raw = fixture
            } else {
                raw = try await Transcriber.transcribe(url)
            }
            #else
            raw = try await Transcriber.transcribe(url)
            #endif
            try? FileManager.default.removeItem(at: url)
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard run == generation else { return }
            guard !text.isEmpty else {
                phase = .failed("No speech detected. Check the microphone and try again.")
                return
            }
            let pending = await correct(text, model: model)
            guard run == generation else { return }
            phase = .result(pending)
            PendingDictation.current = pending
        } catch {
            try? FileManager.default.removeItem(at: url)
            guard run == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func correct(_ raw: String, model: ModelService) async -> PendingDictation {
        let defaults = AppGroup.defaults
        guard defaults.object(forKey: SharedKeys.spokenCorrections) as? Bool ?? true else {
            return PendingDictation(text: raw, heard: raw, changes: [])
        }
        let result = SpokenCorrections.apply(raw)
        let useModel = defaults.object(forKey: SharedKeys.useModelForCorrections) as? Bool ?? true
        if result.needsModel, useModel, model.status == .ready,
           let fixed = try? await model.run(.correct, text: raw) {
            return PendingDictation(text: fixed, heard: raw, changes: result.changes)
        }
        return PendingDictation(text: result.text, heard: raw, changes: result.changes)
    }

    func reset() { phase = .idle }

    private func stopRecorder() {
        meter?.invalidate()
        meter = nil
        recorder?.stop()
        recorder = nil
    }
}
