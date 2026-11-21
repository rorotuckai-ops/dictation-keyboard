import AVFoundation
import SwiftUI

struct DictateView: View {
    @ScaledMetric(relativeTo: .title2) private var resultSize = 23
    @Environment(ModelService.self) private var model
    @Environment(BridgeServer.self) private var server
    @Environment(\.scenePhase) private var scenePhase
    @State private var flow = HostDictation()
    @State private var recording = false
    @State private var pending = PendingDictation.current
    @State private var speechReady = true
    @State private var micDenied = AVAudioApplication.shared.recordPermission == .denied
    @State private var preparing = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
              ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if server.returnHint {
                        Label(server.busy ? "Working on your text…" : "Done. Tap ◀ at the top left to go back to your app.",
                              systemImage: server.busy ? "hourglass" : "checkmark.circle")
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("host.returnHint")
                    }
                    if micDenied || !speechReady { setupProblem }
                    if let pending, !pending.expired {
                        pendingCard(pending)
                    } else {
                        VStack(spacing: 8) {
                            Text("No pending text").font(.title3.weight(.semibold)).foregroundStyle(Color.ink)
                            Text("Record here or start from your keyboard.").font(.subheadline).foregroundStyle(Color.inkSecondary)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: micDenied || !speechReady || server.returnHint ? 160 : max(0, geometry.size.height - 48))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
              }
            }
            .background(Color.paper)
            .navigationTitle("Dictate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { LanguageView() } label: {
                        HStack(spacing: 6) {
                            Text(DictationLocale.name)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .frame(minHeight: 44)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    RecordButton(symbol: "mic", label: "Record") {
                        recording = true
                        Task { await flow.start() }
                    }
                    .accessibilityIdentifier("host.record")
                    Text("Record").font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
                .background(Color.paper)
            }
            .fullScreenCover(isPresented: $recording, onDismiss: refresh) {
                RecordingView(flow: flow, model: model) { recording = false }
            }
            .task { await checkSpeech() }
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        }
    }

    private var setupProblem: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(micDenied ? "Microphone access is off" : "Offline speech isn't installed")
                .font(.headline).foregroundStyle(Color.ink)
            Text(micDenied ? "Turn it on in Settings to record." : "Download the on-device speech model once; dictation then works offline.")
                .font(.subheadline).foregroundStyle(Color.inkSecondary)
            Button(micDenied ? "Open Settings" : (preparing ? "Downloading…" : "Download speech model")) {
                if micDenied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } else {
                    Task { preparing = true; try? await Transcriber.prepareAssets(); preparing = false; await checkSpeech() }
                }
            }
            .disabled(preparing)
            .accessibilityIdentifier("host.prepareSpeech")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func pendingCard(_ pending: PendingDictation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pending text").font(.footnote).foregroundStyle(Color.inkSecondary)
            Text(pending.text)
                .font(.system(size: resultSize))
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("host.pendingText")
            Text("Switch to your app and tap Insert on the keyboard.")
                .font(.footnote).foregroundStyle(Color.inkSecondary)
            HStack(spacing: 12) {
                Button { UIPasteboard.general.string = pending.text } label: {
                    Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44)
                }
                Button(role: .destructive) { PendingDictation.current = nil; refresh() } label: {
                    Text("Discard").frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .buttonStyle(.bordered)
            .tint(.ink)
        }
    }

    private func refresh() {
        pending = PendingDictation.current
        micDenied = AVAudioApplication.shared.recordPermission == .denied
    }

    private func checkSpeech() async {
        #if DEBUG
        if DebugFixture.transcriptText != nil { speechReady = true; return }
        #endif
        speechReady = await Transcriber.assetsInstalled()
    }
}

struct LanguageView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Dictation language", value: DictationLocale.name)
            } footer: {
                Text("Dictation uses your iPhone's language. Change it in Settings › General › Language & Region.")
            }
            .listRowBackground(Color.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}
