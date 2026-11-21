import AVFoundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ModelService.self) private var model
    @AppStorage(SharedKeys.spokenCorrections, store: AppGroup.defaults) private var spokenCorrections = true
    @AppStorage(SharedKeys.useModelForCorrections, store: AppGroup.defaults) private var useModel = true
    @AppStorage(SharedKeys.haptics, store: AppGroup.defaults) private var haptics = true
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack {
            List {
                Section("Dictation") {
                    NavigationLink { LanguageView() } label: { LabeledContent("Language", value: DictationLocale.name) }
                    Toggle(isOn: $spokenCorrections) {
                        Text("Spoken corrections")
                        Text("Apply “sorry, I mean…”")
                    }
                    Toggle(isOn: $useModel) {
                        Text("Harder corrections with Gemma")
                        Text("When the rules aren't sure")
                    }
                    .disabled(!spokenCorrections)
                }
                Section("Setup") {
                    NavigationLink { ModelsView() } label: {
                        row("Models", symbol: "folder", detail: model.status == .ready ? model.modelName : "Not added")
                    }
                    .accessibilityIdentifier("settings.models")
                    NavigationLink { KeyboardSetupView() } label: {
                        row("Keyboard", symbol: "keyboard", detail: KeyboardSetupView.fullAccessConfirmed ? "Full Access confirmed" : "Full Access not confirmed")
                    }
                    .accessibilityIdentifier("settings.keyboard")
                    NavigationLink { PrivacyView() } label: { row("Privacy", symbol: "lock", detail: nil) }
                }
                Section("Preferences") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Toggle("Haptics", isOn: $haptics)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .navigationTitle("Settings")
        }
    }

    private func row(_ title: String, symbol: String, detail: String?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.footnote).foregroundStyle(Color.inkSecondary) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.ink)
        }
    }
}

struct ModelsView: View {
    @Environment(ModelService.self) private var model
    @Environment(BridgeServer.self) private var server
    @State private var importing = false
    @State private var confirmRemove = false
    @State private var speechReady = false

    var body: some View {
        @Bindable var server = server
        List {
            Section {
                switch model.status {
                case .ready:
                    LabeledContent(model.modelName, value: "Ready").accessibilityIdentifier("host.modelReady")
                    if let size = model.modelSize { LabeledContent("Size", value: size) }
                    Button("Replace from Files") { importing = true }
                    Button("Remove model", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("host.removeModel")
                case .loading:
                    HStack { ProgressView(); Text("Loading \(model.modelName)…") }
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Downloading Gemma 4 E2B (2.6 GB)…")
                        ProgressView(value: progress).animation(.linear(duration: 0.2), value: progress)
                    }
                case .missing, .failed:
                    if case .failed(let message) = model.status {
                        Text(message).font(.footnote).foregroundStyle(Color.destructiveInk)
                    }
                    Text("No cleanup model added. Dictation works without it; Fix and Rewrite need it.")
                        .foregroundStyle(Color.inkSecondary)
                    Button("Download Gemma 4 E2B (2.6 GB, Wi-Fi)") { model.startDownload() }
                    Button("Import .litertlm from Files") { importing = true }
                }
            } header: {
                Text("Cleanup model")
            } footer: {
                Text("Gemma runs on this iPhone. Text never leaves it.")
            }
            Section {
                LabeledContent("Offline speech", value: speechReady ? "Installed" : "Not installed")
            } header: {
                Text("Speech")
            } footer: {
                Text("Apple's on-device speech model for \(DictationLocale.name).")
            }
            Section {
                Toggle("Stay ready in background", isOn: $server.stayReady)
            } footer: {
                Text("Keeps the app running so the keyboard's Fix works without switching apps.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(model.modelName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove model", role: .destructive) { model.removeModel() }
        } message: {
            Text("Fix and Rewrite stop working until you add a model again. Dictation keeps working.")
        }
        .task { speechReady = await Transcriber.assetsInstalled() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { Task { await model.importModel(from: url) } }
        }
    }
}

struct KeyboardSetupView: View {
    @State private var micAllowed = AVAudioApplication.shared.recordPermission == .granted
    @State private var speechReady = false
    @State private var speechMessage: String?
    @State private var trial = ""
    @State private var trialResult = ""

    /// Full Access counts as confirmed only after the keyboard has reported in recently.
    static var fullAccessConfirmed: Bool {
        Date().timeIntervalSince1970 - AppGroup.defaults.double(forKey: SharedKeys.keyboardHandshake) < 10 * 60
    }

    var body: some View {
        List {
            Section {
                Text("Settings › General › Keyboard › Keyboards › Add New Keyboard › **Dictation Keyboard**, then turn on **Allow Full Access**.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                LabeledContent("Full Access", value: Self.fullAccessConfirmed ? "Confirmed" : "Not confirmed")
            } header: {
                Text("Turn on the keyboard")
            } footer: {
                Text("The keyboard needs Full Access for the microphone and to talk to this app.")
            }
            Section("Speech on this iPhone") {
                LabeledContent("Microphone", value: micAllowed ? "Allowed" : "Not allowed")
                LabeledContent("Offline speech", value: speechReady ? "Installed" : "Not installed")
                if let speechMessage { Text(speechMessage).font(.footnote).foregroundStyle(Color.inkSecondary) }
                if !micAllowed || !speechReady {
                    Button("Allow mic and download speech") { Task { await prepare() } }
                        .accessibilityIdentifier("host.prepareSpeech")
                }
            }
            Section("Test") {
                TextField("Tap here and switch to Dictation Keyboard", text: $trial, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("host.playground")
                Button("Apply spoken corrections") { trialResult = SpokenCorrections.apply(trial).text }
                    .accessibilityIdentifier("host.applyCorrections")
                if !trialResult.isEmpty { Text(trialResult).accessibilityIdentifier("host.result") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private func refresh() async {
        micAllowed = AVAudioApplication.shared.recordPermission == .granted
        speechReady = await Transcriber.assetsInstalled()
    }

    private func prepare() async {
        micAllowed = await AVAudioApplication.requestRecordPermission()
        _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        do {
            speechMessage = "Downloading…"
            try await Transcriber.prepareAssets()
            speechMessage = nil
        } catch {
            speechMessage = error.localizedDescription
        }
        await refresh()
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Speech is recognized on this iPhone. Audio is kept only until it's transcribed.")
                Text("Gemma cleans up text on this iPhone. Nothing is sent to a server.")
                Text("No accounts, no analytics, no history of what you dictate.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
