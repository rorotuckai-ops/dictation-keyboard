import AVFoundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ModelService.self) private var model
    @Environment(BridgeServer.self) private var server
    @State private var importing = false
    @State private var micAllowed = AVAudioApplication.shared.recordPermission == .granted
    @State private var speechReady = false
    @State private var speechMessage: String?
    @State private var playground = ""
    @State private var playgroundResult = ""
    @AppStorage(SharedKeys.useModelForCorrections, store: AppGroup.defaults) private var useModelForCorrections = true
    @AppStorage(SharedKeys.rewriteMode, store: AppGroup.defaults) private var rewriteMode = false

    var body: some View {
        @Bindable var server = server
        NavigationStack {
            Form {
                if server.returnHint {
                    Section {
                        Label(server.busy ? "Working on your text…" : "Done. Tap ◀ at the top left to go back to your app.",
                              systemImage: server.busy ? "hourglass" : "checkmark.circle.fill")
                            .accessibilityIdentifier("host.returnHint")
                    }
                }
                Section("1 · Turn on the keyboard") {
                    Text("Settings › General › Keyboard › Keyboards › Add New Keyboard › **Dictation Keyboard**, then tap it and turn on **Allow Full Access** (needed for the mic and for talking to this app).")
                        .font(.callout)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("2 · Microphone and on-device speech") {
                    statusRow("Microphone", ok: micAllowed)
                    statusRow("Speech model on this iPhone", ok: speechReady)
                    if let speechMessage { Text(speechMessage).font(.footnote).foregroundStyle(.secondary) }
                    if !micAllowed || !speechReady {
                        Button("Allow mic and download speech model") { Task { await prepareSpeech() } }
                            .accessibilityIdentifier("host.prepareSpeech")
                    }
                }
                Section {
                    modelRow
                    Toggle("Stay ready in background", isOn: $server.stayReady)
                    Toggle("Use Gemma for tricky spoken corrections", isOn: $useModelForCorrections)
                    Toggle("Fix button rewrites (instead of light cleanup)", isOn: $rewriteMode)
                } header: {
                    Text("3 · Gemma (offline)")
                } footer: {
                    Text("The model runs entirely on this iPhone. Leave this app open in the background so the keyboard's Fix button works without switching apps.")
                }
                Section("Try it") {
                    TextField("Type or dictate here", text: $playground, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("host.playground")
                    HStack {
                        Button("Apply spoken corrections") {
                            playgroundResult = SpokenCorrections.apply(playground).text
                        }
                        .accessibilityIdentifier("host.applyCorrections")
                        Spacer()
                        Button("Fix with Gemma") {
                            Task {
                                playgroundResult = (try? await model.run(rewriteMode ? .rewrite : .fix, text: playground)) ?? "Gemma isn't ready"
                            }
                        }
                        .disabled(model.status != .ready)
                        .accessibilityIdentifier("host.fix")
                    }
                    .buttonStyle(.borderless)
                    if !playgroundResult.isEmpty {
                        Text(playgroundResult).accessibilityIdentifier("host.result")
                    }
                }
            }
            .navigationTitle("Dictation Keyboard")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
                if case .success(let url) = result { Task { await model.importModel(from: url) } }
            }
            .task { await refreshSpeech() }
        }
    }

    @ViewBuilder private var modelRow: some View {
        switch model.status {
        case .ready:
            statusRow(model.modelName, ok: true).accessibilityIdentifier("host.modelReady")
        case .loading:
            HStack { ProgressView(); Text("Loading \(model.modelName)…") }
        case .downloading(let p):
            VStack(alignment: .leading) {
                Text("Downloading Gemma 4 E2B (2.6 GB)…")
                ProgressView(value: p)
            }
        case .missing, .failed:
            if case .failed(let message) = model.status {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            Text("Add a Gemma `.litertlm` model once; after that everything works offline.").font(.callout)
            Button("Download Gemma 4 E2B (2.6 GB, Wi-Fi)") { model.startDownload() }
            Button("Import .litertlm from Files") { importing = true }
        }
    }

    private func statusRow(_ title: String, ok: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }

    private func refreshSpeech() async {
        micAllowed = AVAudioApplication.shared.recordPermission == .granted
        speechReady = await Transcriber.assetsInstalled()
    }

    private func prepareSpeech() async {
        micAllowed = await AVAudioApplication.requestRecordPermission()
        _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        do {
            speechMessage = "Downloading…"
            try await Transcriber.prepareAssets()
            speechMessage = nil
        } catch {
            speechMessage = error.localizedDescription
        }
        await refreshSpeech()
    }
}
