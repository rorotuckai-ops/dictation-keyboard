import AVFoundation
import Foundation
import Speech

/// On-device speech to text for a recorded clip: iOS 26 SpeechAnalyzer, falling back to
/// SFSpeechRecognizer with `requiresOnDeviceRecognition`. Nothing leaves the device.
enum Transcriber {
    enum Failure: LocalizedError {
        case unsupportedLocale
        case noSpeech
        case onDeviceUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: "On-device speech doesn't support this language."
            case .noSpeech: "No speech heard."
            case .onDeviceUnavailable: "On-device speech recognition isn't available. Open the app once to download the speech model."
            }
        }
    }

    static var locale: Locale { Locale(identifier: Locale.preferredLanguages.first ?? "en-US") }

    static func transcribe(_ url: URL) async throws -> String {
        do {
            let text = try await analyzer(url)
            if !text.isEmpty { return text }
        } catch {
            NSLog("[DictKB] SpeechAnalyzer failed: \(error)")
        }
        let text = try await legacy(url)
        guard !text.isEmpty else { throw Failure.noSpeech }
        return text
    }

    /// Downloads Apple's on-device speech assets for the current language (one-time setup).
    static func prepareAssets() async throws {
        let module = try await module()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) {
            try await request.downloadAndInstall()
        }
    }

    static func assetsInstalled() async -> Bool {
        guard let module = try? await module() else { return false }
        return await AssetInventory.status(forModules: [module.module]) == .installed
    }

    private enum Module {
        case dictation(DictationTranscriber)
        case speech(SpeechTranscriber)

        var module: any SpeechModule {
            switch self {
            case .dictation(let t): t
            case .speech(let t): t
            }
        }

        func finalText() async throws -> String {
            var out = AttributedString()
            switch self {
            case .dictation(let t):
                for try await r in t.results where r.isFinal { out += r.text }
            case .speech(let t):
                for try await r in t.results where r.isFinal { out += r.text }
            }
            return String(out.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func module() async throws -> Module {
        if SpeechTranscriber.isAvailable, let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speech(SpeechTranscriber(locale: match, transcriptionOptions: [], reportingOptions: [], attributeOptions: []))
        }
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(DictationTranscriber(locale: match, preset: .longDictation))
        }
        throw Failure.unsupportedLocale
    }

    private static func analyzer(_ url: URL) async throws -> String {
        let module = try await module()
        if await AssetInventory.status(forModules: [module.module]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) {
                try await request.downloadAndInstall()
            }
        }
        let analyzer = SpeechAnalyzer(
            modules: [module.module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
        let file = try AVAudioFile(forReading: url)
        async let text = module.finalText()
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await text
    }

    private static func legacy(_ url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else { throw Failure.onDeviceUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
