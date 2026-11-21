import SwiftUI

/// H07 recording → H08 processing → H09 result with the correction diff.
struct RecordingView: View {
    @ScaledMetric(relativeTo: .title2) private var transcriptSize = 25
    let flow: HostDictation
    let model: ModelService
    var close: () -> Void

    var body: some View {
        NavigationStack {
            content
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.paper)
                .navigationTitle("Dictation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { flow.cancel(); close() } label: { Image(systemName: "chevron.left") }
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(Color.ink)
                            .accessibilityLabel("Back")
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: flow.phase)
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.phase {
        case .idle, .recording:
            recording
        case .processing:
            VStack(spacing: 16) {
                ProgressView()
                Text("Processing dictation…").font(.body).foregroundStyle(Color.inkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .result(let pending):
            ResultView(pending: pending)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 16) {
                Text("Couldn't finish dictation").font(.largeTitle.bold()).foregroundStyle(Color.ink)
                Text(message).foregroundStyle(Color.inkSecondary).accessibilityIdentifier("host.recordError")
                Spacer()
                PrimaryButton(title: "Try again", symbol: nil) { Task { await flow.start() } }
                Button("Close") { flow.reset(); close() }.frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.top, 16)
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Listening").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentInk)
                Spacer()
                TimelineView(.periodic(from: flow.started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(flow.started)))
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.top, 16)
            Text("Speak naturally. Say “sorry, I mean…” to correct yourself.")
                .font(.system(size: transcriptSize)).foregroundStyle(Color.inkSecondary)
            Spacer()
            Meter(levels: flow.levels).frame(height: 56)
            ZStack {
                RecordButton(symbol: "stop.fill", label: "Stop recording") { Task { await flow.stop(model: model) } }
                    .accessibilityIdentifier("host.stop")
                HStack {
                    Button("Cancel") { flow.cancel(); close() }
                        .foregroundStyle(Color.inkSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                    Spacer()
                }
            }
            Text("Stop recording").font(.body.weight(.semibold)).foregroundStyle(Color.ink).frame(maxWidth: .infinity)
                .padding(.bottom, 16)
        }
    }
}

/// Live input level from the recorder; nothing is drawn while silent or idle.
private struct Meter: View {
    var levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(Color.accentInk).frame(width: 3, height: max(4, CGFloat(level) * 56))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct ResultView: View {
    @ScaledMetric(relativeTo: .title2) private var resultSize = 23
    let pending: PendingDictation
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Ready to insert").font(.largeTitle.bold()).foregroundStyle(Color.ink)
                Text(pending.text)
                    .font(.system(size: resultSize))
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("host.resultText")
                if !pending.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Corrections").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                        ForEach(pending.changes, id: \.self) { CorrectionDiff(change: $0) }
                    }
                }
                if pending.heard != pending.text {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What we heard").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                        Text(pending.heard).foregroundStyle(Color.inkSecondary).textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 8)
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Text("Switch back to your app, then tap Insert.").font(.footnote).foregroundStyle(Color.inkSecondary)
                PrimaryButton(title: copied ? "Copied" : "Copy text", symbol: "doc.on.doc") {
                    UIPasteboard.general.string = pending.text
                    copied = true
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(Color.paper.ignoresSafeArea(edges: .bottom))
        }
    }
}

/// "Monday → Tuesday": struck-through source, arrow, underlined neutral-filled insertion.
struct CorrectionDiff: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let change: CorrectionChange

    var body: some View {
        Group {
            if change.to.isEmpty {
                source
            } else if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        source
                        arrow("arrow.right")
                        replacement
                    }
                    .fixedSize()
                    stacked
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(change.to.isEmpty ? "Removed \(change.from)" : "\(change.from) changed to \(change.to)")
        .accessibilityIdentifier("host.correction")
    }

    private var source: some View {
        Text(change.from).strikethrough().foregroundStyle(Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var replacement: some View {
        Text(change.to).underline().foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.insertion, in: RoundedRectangle(cornerRadius: 4))
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            source.frame(maxWidth: .infinity, alignment: .leading)
            arrow("arrow.down")
            replacement
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.caption).foregroundStyle(Color.inkSecondary)
            .accessibilityHidden(true)
    }
}
