import UIKit

final class KeyboardViewController: UIInputViewController {
    private enum State: Equatable {
        case idle
        case listening
        case transcribing
        case fixing
    }

    private var state: State = .idle { didSet { render() } }
    private var mic: MicCapture?
    private let keys = KeysView()
    private let micButton = UIButton(type: .system)
    private let fixButton = UIButton(type: .system)
    private let rewriteButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let status = UILabel()
    private var pending: PendingEdit?
    private var waitTask: Task<Void, Never>?

    /// A model edit handed to the host app, remembered so it can be applied after a round trip.
    private struct PendingEdit: Codable {
        var id: UUID
        var original: String
        var selection: Bool
        var before: Int
        var after: Int
        var insertion: Bool
        var fallback: String?
    }

    private var rewriteMode: Bool {
        get { AppGroup.defaults.bool(forKey: SharedKeys.rewriteMode) }
        set { AppGroup.defaults.set(newValue, forKey: SharedKeys.rewriteMode) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumePendingEdit()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if state == .listening { _ = mic?.stop(); state = .idle }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeButton.isHidden = !needsInputModeSwitchKey
    }

    // MARK: Layout

    private func buildLayout() {
        guard let root = inputView else { return }
        root.allowsSelfSizing = true

        configure(micButton, symbol: "mic.fill", title: nil, id: "kb.mic", label: "Dictate")
        micButton.tintColor = .white
        micButton.backgroundColor = .systemBlue
        micButton.layer.cornerRadius = 20
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        configure(fixButton, symbol: "wand.and.stars", title: "Fix", id: "kb.fix", label: "Fix text")
        fixButton.addTarget(self, action: #selector(fixTapped), for: .touchUpInside)

        configure(rewriteButton, symbol: "text.quote", title: "Rewrite", id: "kb.rewrite", label: "Rewrite mode")
        rewriteButton.addTarget(self, action: #selector(rewriteTapped), for: .touchUpInside)

        configure(globeButton, symbol: "globe", title: nil, id: "kb.globe", label: "Next keyboard")
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.7
        status.accessibilityIdentifier = "kb.status"
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = UIStackView(arrangedSubviews: [globeButton, fixButton, rewriteButton, status, micButton])
        bar.axis = .horizontal
        bar.spacing = 8
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false

        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.onKey = { [weak self] in self?.handle($0) }

        root.addSubview(bar)
        root.addSubview(keys)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 40),
            micButton.widthAnchor.constraint(equalToConstant: 64),
            micButton.heightAnchor.constraint(equalToConstant: 40),
            globeButton.widthAnchor.constraint(equalToConstant: 36),
            keys.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            keys.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 3),
            keys.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -3),
            keys.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            keys.heightAnchor.constraint(equalToConstant: 210),
        ])
    }

    private func configure(_ button: UIButton, symbol: String, title: String?, id: String, label: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.title = title
        config.imagePadding = 4
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        button.configuration = config
        button.accessibilityIdentifier = id
        button.accessibilityLabel = label
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 10
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func render() {
        micButton.configuration?.image = UIImage(systemName: state == .listening ? "stop.fill" : "mic.fill")
        micButton.backgroundColor = state == .listening ? .systemRed : .systemBlue
        micButton.accessibilityLabel = state == .listening ? "Stop dictation" : "Dictate"
        micButton.isEnabled = state == .idle || state == .listening
        fixButton.isEnabled = state == .idle
        rewriteButton.backgroundColor = rewriteMode ? UIColor.systemBlue.withAlphaComponent(0.25) : .secondarySystemBackground
        rewriteButton.accessibilityValue = rewriteMode ? "on" : "off"
        switch state {
        case .idle: if status.text?.hasSuffix("…") == true { status.text = nil }
        case .listening: status.text = "Listening…"
        case .transcribing: status.text = "Transcribing…"
        case .fixing: status.text = rewriteMode ? "Rewriting…" : "Fixing…"
        }
    }

    private func show(_ message: String?) {
        status.text = message
    }

    // MARK: Typing

    private func handle(_ key: KeysView.Key) {
        let proxy = textDocumentProxy
        switch key {
        case .character(let c): proxy.insertText(c)
        case .space: proxy.insertText(" ")
        case .delete: proxy.deleteBackward()
        case .return: proxy.insertText("\n")
        }
    }

    // MARK: Dictation

    @objc private func micTapped() {
        switch state {
        case .idle: startListening()
        case .listening: finishListening()
        default: break
        }
    }

    private func startListening() {
        guard hasFullAccess else {
            show("Allow Full Access for the mic")
            return
        }
        #if DEBUG
        if let fixture = DebugFixture.transcript ?? DebugFixture.audio {
            state = .listening
            show(fixture.pathExtension == "txt" ? "Listening… (test transcript)" : "Listening… (test clip)")
            fixtureClip = fixture
            return
        }
        #endif
        if mic == nil, let root = inputView {
            let capture = MicCapture(host: root)
            capture.onEvent = { [weak self] event in
                guard let self else { return }
                switch event {
                case .started: self.show("Listening…")
                case .level: break
                case .failed(let message):
                    self.state = .idle
                    self.show("Mic: \(message)")
                }
            }
            mic = capture
        }
        state = .listening
        mic?.start()
    }

    #if DEBUG
    private var fixtureClip: URL?
    #endif

    private func finishListening() {
        var clip: URL?
        #if DEBUG
        clip = fixtureClip
        fixtureClip = nil
        #endif
        if clip == nil, let mic {
            let pcm = mic.stop()
            guard pcm.count > mic.sampleRate / 4 else {
                state = .idle
                show("Didn't catch that")
                return
            }
            let url = AppGroup.directory("audio").appendingPathComponent("dictation.wav")
            do {
                try WAVFile.write(samples: pcm, sampleRate: mic.sampleRate, to: url)
                clip = url
            } catch {
                state = .idle
                show("Couldn't save audio")
                return
            }
        }
        guard let clip else { state = .idle; return }
        state = .transcribing
        Task { @MainActor in
            #if DEBUG
            if clip.pathExtension == "txt", let raw = try? String(contentsOf: clip, encoding: .utf8) {
                await self.insertDictation(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            #endif
            do {
                let raw = try await Transcriber.transcribe(clip)
                await self.insertDictation(raw)
            } catch {
                // Speech can be unavailable inside the extension; the app transcribes the same clip.
                NSLog("[DictKB] keyboard transcription failed: \(error)")
                let path = String(clip.path.dropFirst(AppGroup.container.path.count + 1))
                if Bridge.hostIsAlive, let raw = await self.askHost(.transcribe, text: path, timeout: 30), !raw.isEmpty {
                    await self.insertDictation(raw)
                } else {
                    self.state = .idle
                    self.show(error.localizedDescription)
                }
            }
        }
    }

    private func insertDictation(_ raw: String) async {
        let corrected = SpokenCorrections.apply(raw)
        let useModel = AppGroup.defaults.object(forKey: SharedKeys.useModelForCorrections) as? Bool ?? true
        if corrected.needsModel, useModel, Bridge.hostIsAlive {
            state = .fixing
            if let text = await askHost(.correct, text: raw, timeout: 30) {
                insert(dictated: text)
                show("Corrected with Gemma")
                state = .idle
                return
            }
        }
        insert(dictated: corrected.text)
        show(corrected.applied > 0 ? "Applied \(corrected.applied) correction\(corrected.applied == 1 ? "" : "s")" : nil)
        state = .idle
    }

    private func insert(dictated text: String) {
        guard !text.isEmpty else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        var out = text
        if let last = before.last, !last.isWhitespace, !(textDocumentProxy.selectedText?.isEmpty == false) {
            out = " " + out
        }
        textDocumentProxy.insertText(out)
    }

    // MARK: Fix

    @objc private func rewriteTapped() {
        rewriteMode.toggle()
        show(rewriteMode ? "Rewrite mode on" : "Rewrite mode off")
        render()
    }

    @objc private func fixTapped() {
        guard state == .idle else { return }
        guard hasFullAccess else {
            show("Allow Full Access to use Fix")
            return
        }
        let proxy = textDocumentProxy
        let edit: PendingEdit
        if let selected = proxy.selectedText, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            edit = PendingEdit(id: UUID(), original: selected, selection: true, before: 0, after: 0, insertion: false)
        } else {
            let before = proxy.documentContextBeforeInput ?? ""
            let after = proxy.documentContextAfterInput ?? ""
            let text = before + after
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                show("Nothing to fix")
                return
            }
            edit = PendingEdit(id: UUID(), original: text, selection: false, before: before.count, after: after.count, insertion: false)
        }
        let task: BridgeTask = rewriteMode ? .rewrite : .fix
        state = .fixing
        Task { @MainActor in
            if Bridge.hostIsAlive {
                if let text = await self.askHost(task, text: edit.original, timeout: 120) {
                    self.apply(edit, text: text)
                    self.show(task == .rewrite ? "Rewritten" : "Fixed")
                }
                self.state = .idle
            } else {
                self.handOff(task, edit: edit)
            }
        }
    }

    /// Host app isn't running: queue the request and open the app, which processes it and
    /// tells the user to return; the result is applied when the keyboard reappears.
    private func handOff(_ task: BridgeTask, edit: PendingEdit) {
        let request = BridgeRequest(id: edit.id, task: task, text: edit.original, created: Date())
        do {
            try Bridge.submit(request)
        } catch {
            state = .idle
            show("Couldn't reach the app")
            return
        }
        pending = edit
        if let data = try? JSONEncoder().encode(edit) { AppGroup.defaults.set(data, forKey: "pendingEdit") }
        show("Opening Dictation Keyboard…")
        if !HostAppOpener.open(URL(string: "dictkb://process?id=\(edit.id.uuidString)")!, from: self) {
            show("Open the Dictation Keyboard app to load Gemma")
        }
        state = .idle
        waitForPending()
    }

    private func resumePendingEdit() {
        if pending == nil, let data = AppGroup.defaults.data(forKey: "pendingEdit") {
            pending = try? JSONDecoder().decode(PendingEdit.self, from: data)
        }
        if pending != nil { waitForPending() }
    }

    private func waitForPending() {
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            for _ in 0..<600 {
                guard let edit = self.pending else { return }
                if let response = Bridge.takeResponse(edit.id) {
                    self.pending = nil
                    AppGroup.defaults.removeObject(forKey: "pendingEdit")
                    if let text = response.text { self.apply(edit, text: text); self.show("Fixed") }
                    else { self.show(response.error ?? "Gemma failed") }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func askHost(_ task: BridgeTask, text: String, timeout: Double) async -> String? {
        let request = BridgeRequest(id: UUID(), task: task, text: text, created: Date())
        do { try Bridge.submit(request) } catch { show("Couldn't reach the app"); return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = Bridge.takeResponse(request.id) {
                if let error = response.error { show(error) }
                return response.text
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        Bridge.cancel(request.id)
        show("Gemma timed out")
        return nil
    }

    private func apply(_ edit: PendingEdit, text: String) {
        let proxy = textDocumentProxy
        if edit.selection {
            guard proxy.selectedText == edit.original else {
                show("Selection changed; select the text and try again")
                return
            }
            proxy.insertText(text)
            return
        }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        guard before + after == edit.original else {
            show("Text changed while fixing; tap Fix again")
            return
        }
        if !after.isEmpty { proxy.adjustTextPosition(byCharacterOffset: after.count) }
        for _ in 0..<(before.count + after.count) { proxy.deleteBackward() }
        proxy.insertText(text)
    }
}

#if DEBUG
/// Test hook for the simulator, which has no microphone: a clip placed at
/// `<App Group>/fixtures/dictation.wav` stands in for the mic in Debug builds.
enum DebugFixture {
    static var audio: URL? {
        let url = AppGroup.container.appendingPathComponent("fixtures/dictation.wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The simulator's speech service can't run recognition, so `fixtures/dictation.txt` stands in
    /// for the recognizer's output; the rest of the pipeline (corrections, insertion) runs as normal.
    static var transcript: URL? {
        let url = AppGroup.container.appendingPathComponent("fixtures/dictation.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif
