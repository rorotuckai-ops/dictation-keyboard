import UIKit

final class KeyboardViewController: UIInputViewController {
    private enum State: Equatable {
        case idle
        case listening
        case transcribing
        case fixing(BridgeTask)
    }

    private var state: State = .idle { didSet { render() } }
    private var mic: MicCapture?
    private let keys = KeysView()
    private let header = UILabel()
    private let undoButton = UIButton(type: .system)
    private let preview = UILabel()
    private let micButton = UIButton(type: .system)
    private let fixButton = UIButton(type: .system)
    private let rewriteButton = UIButton(type: .system)
    private let discardButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let tools = UIView()
    private let review = UIView()
    private let reviewText = UILabel()
    private let reviewSpacer = UIView()
    private let globeButton = UIButton(type: .system)
    private let lettersButton = UIButton(type: .system)
    private let spaceKey = KeyButton(wide: false) {}
    private var message: String?
    private var lettersShown = false { didSet { render() } }
    private var pending: PendingEdit?
    private var waitTask: Task<Void, Never>?
    /// On screen in an active app; a response applied otherwise edits nothing.
    private var visible = false
    private var deleteTimer: Timer?
    /// The last Fix, Rewrite or Insert, so Undo can restore what was there before.
    private var lastEdit: (original: String, result: String)?

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

    private var hostDictation: PendingDictation? {
        guard let value = PendingDictation.current else { return nil }
        if value.expired { PendingDictation.current = nil; return nil }
        return value
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        render()
        // Opening the app doesn't take the keyboard's view off screen, so follow the text field's app instead.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(hostInactive), name: .NSExtensionHostWillResignActive, object: nil)
        center.addObserver(self, selector: #selector(hostActive), name: .NSExtensionHostDidBecomeActive, object: nil)
    }

    @objc private func hostInactive() {
        visible = false
        waitTask?.cancel()
    }

    @objc private func hostActive() {
        guard view.window != nil else { return }
        visible = true
        resumePendingEdit()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasFullAccess { AppGroup.defaults.set(Date().timeIntervalSince1970, forKey: SharedKeys.keyboardHandshake) }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        resumePendingEdit()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hostInactive()
        if state == .listening { _ = mic?.stop(); state = .idle }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeButton.isHidden = !needsInputModeSwitchKey
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        render()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        render()
    }

    // MARK: Layout

    private func buildLayout() {
        guard let root = inputView else { return }
        root.allowsSelfSizing = true
        root.backgroundColor = Palette.keyboard

        header.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14, weight: .semibold), maximumPointSize: 20)
        header.textColor = Palette.text
        header.adjustsFontForContentSizeCategory = true
        header.accessibilityIdentifier = "kb.status"
        header.accessibilityTraits.insert(.updatesFrequently)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var undo = UIButton.Configuration.plain()
        undo.title = "Undo"
        undo.baseForegroundColor = Palette.text
        undoButton.configuration = undo
        undoButton.accessibilityIdentifier = "kb.undo"
        undoButton.accessibilityLabel = "Undo last edit"
        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)

        preview.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17), maximumPointSize: 36)
        preview.adjustsFontForContentSizeCategory = true
        preview.numberOfLines = 3
        preview.lineBreakMode = .byTruncatingTail
        preview.accessibilityIdentifier = "kb.preview"

        var micConfig = UIButton.Configuration.filled()
        micConfig.cornerStyle = .capsule
        micConfig.baseBackgroundColor = Palette.accent
        micConfig.baseForegroundColor = Palette.onAccent
        micConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        micButton.configuration = micConfig
        micButton.accessibilityIdentifier = "kb.mic"
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        action(fixButton, title: "Fix text", symbol: "checkmark", id: "kb.fix", label: "Fix text")
        fixButton.addTarget(self, action: #selector(fixTapped), for: .touchUpInside)
        action(rewriteButton, title: "Rewrite", symbol: nil, id: "kb.rewrite", label: "Rewrite text")
        rewriteButton.addTarget(self, action: #selector(rewriteTapped), for: .touchUpInside)

        var discard = UIButton.Configuration.plain()
        discard.title = "Discard"
        discard.baseForegroundColor = Palette.secondary
        discardButton.configuration = discard
        discardButton.accessibilityIdentifier = "kb.discard"
        discardButton.addTarget(self, action: #selector(discardTapped), for: .touchUpInside)
        var insert = UIButton.Configuration.filled()
        insert.title = "Insert"
        insert.baseBackgroundColor = Palette.accent
        insert.baseForegroundColor = Palette.onAccent
        insert.cornerStyle = .fixed
        insert.background.cornerRadius = 9
        insert.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        insertButton.configuration = insert
        insertButton.accessibilityIdentifier = "kb.insert"
        insertButton.accessibilityLabel = "Insert dictated text"
        insertButton.addTarget(self, action: #selector(insertTapped), for: .touchUpInside)

        utility(globeButton, symbol: "globe", id: "kb.globe", label: "Next keyboard")
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        utility(lettersButton, symbol: "keyboard", id: "kb.letters", label: "Letters")
        lettersButton.addTarget(self, action: #selector(lettersTapped), for: .touchUpInside)
        spaceKey.setTitle("space", for: .normal)
        spaceKey.setTitleColor(Palette.secondary, for: .normal)
        spaceKey.accessibilityIdentifier = "key.space"
        spaceKey.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        let delete = KeyButton(wide: true) { [weak self] in self?.textDocumentProxy.deleteBackward() }
        delete.setImage(UIImage(systemName: "delete.left"), for: .normal)
        delete.tintColor = Palette.text
        delete.accessibilityIdentifier = "key.delete"
        delete.accessibilityLabel = "delete"
        delete.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(deleteHeld(_:))))
        let enter = KeyButton(wide: true) { [weak self] in self?.textDocumentProxy.insertText("\n") }
        enter.setImage(UIImage(systemName: "return"), for: .normal)
        enter.tintColor = Palette.text
        enter.accessibilityIdentifier = "key.return"
        enter.accessibilityLabel = "return"

        keys.onKey = { [weak self] key in
            if case .character(let c) = key { self?.textDocumentProxy.insertText(c) }
        }

        let headerRow = UIStackView(arrangedSubviews: [header, undoButton])
        headerRow.alignment = .center
        let actions = UIStackView(arrangedSubviews: [fixButton, rewriteButton])
        actions.spacing = 8
        actions.distribution = .fillEqually
        let top = UIStackView(arrangedSubviews: [preview, micButton])
        top.spacing = 12
        top.alignment = .center
        let toolStack = UIStackView(arrangedSubviews: [top, actions])
        toolStack.axis = .vertical
        toolStack.spacing = 12
        pin(toolStack, in: tools)

        let reviewButtons = UIStackView(arrangedSubviews: [discardButton, reviewSpacer, insertButton])
        reviewButtons.alignment = .center
        reviewButtons.spacing = 8
        discardButton.setContentHuggingPriority(.required, for: .horizontal)
        discardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        reviewText.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17), maximumPointSize: 36)
        reviewText.adjustsFontForContentSizeCategory = true
        reviewText.textColor = Palette.text
        reviewText.numberOfLines = 3
        reviewText.lineBreakMode = .byTruncatingTail
        reviewText.accessibilityIdentifier = "kb.pendingText"
        let reviewStack = UIStackView(arrangedSubviews: [reviewText, UIView(), reviewButtons])
        reviewStack.axis = .vertical
        reviewStack.spacing = 8
        pin(reviewStack, in: review)

        let main = UIView()
        for view in [tools, review, keys] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            main.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: main.topAnchor),
                view.bottomAnchor.constraint(equalTo: main.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: main.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            ])
        }

        let utilityRow = UIStackView(arrangedSubviews: [globeButton, lettersButton, spaceKey, delete, enter])
        utilityRow.spacing = 6
        let separator = UIView()
        separator.backgroundColor = Palette.separator

        let column = UIStackView(arrangedSubviews: [separator, headerRow, main, utilityRow])
        column.axis = .vertical
        column.spacing = 0
        column.setCustomSpacing(4, after: main)
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            headerRow.heightAnchor.constraint(equalToConstant: 44),
            main.heightAnchor.constraint(equalToConstant: 161),
            utilityRow.heightAnchor.constraint(equalToConstant: 50),
            micButton.widthAnchor.constraint(equalToConstant: 66),
            micButton.heightAnchor.constraint(equalToConstant: 66),
            actions.heightAnchor.constraint(equalToConstant: 44),
            insertButton.heightAnchor.constraint(equalToConstant: 44),
            discardButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            undoButton.heightAnchor.constraint(equalToConstant: 44),
            globeButton.widthAnchor.constraint(equalToConstant: 44),
            lettersButton.widthAnchor.constraint(equalToConstant: 44),
            delete.widthAnchor.constraint(equalToConstant: 52),
            enter.widthAnchor.constraint(equalToConstant: 52),
        ])
        for button in [globeButton, lettersButton, spaceKey, delete, enter] as [UIView] {
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        utilityRow.alignment = .center
    }

    private func pin(_ stack: UIStackView, in container: UIView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    private func action(_ button: UIButton, title: String, symbol: String?, id: String, label: String) {
        var config = UIButton.Configuration.filled()
        config.title = title
        if let symbol { config.image = UIImage(systemName: symbol) }
        config.imagePadding = 6
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        config.baseBackgroundColor = Palette.surface
        config.baseForegroundColor = Palette.text
        config.cornerStyle = .fixed
        config.background.cornerRadius = 9
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var a = $0; a.font = .systemFont(ofSize: 15, weight: .medium); return a
        }
        button.configuration = config
        button.accessibilityIdentifier = id
        button.accessibilityLabel = label
    }

    private func utility(_ button: UIButton, symbol: String, id: String, label: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        // Utility targets stay 44 pt; do not inherit an AX-sized button title font.
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        config.baseForegroundColor = Palette.text
        button.configuration = config
        button.accessibilityIdentifier = id
        button.accessibilityLabel = label
    }

    private func render() {
        guard isViewLoaded else { return }
        let ready = state == .idle ? hostDictation : nil
        review.isHidden = ready == nil
        keys.isHidden = ready != nil || !lettersShown
        tools.isHidden = ready != nil || lettersShown
        reviewText.text = ready?.text
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        reviewSpacer.isHidden = accessible
        preview.numberOfLines = accessible ? 2 : 3
        reviewText.numberOfLines = accessible ? 2 : 3
        discardButton.configuration?.title = accessible ? nil : "Discard"
        discardButton.configuration?.image = accessible ? UIImage(systemName: "xmark") : nil
        discardButton.accessibilityLabel = "Discard dictated text"

        lettersButton.configuration?.image = UIImage(systemName: lettersShown ? "mic" : "keyboard")
        lettersButton.accessibilityLabel = lettersShown ? "Dictation tools" : "Letters"

        let listening = state == .listening
        micButton.configuration?.image = UIImage(systemName: listening ? "stop.fill" : "mic.fill")
        micButton.accessibilityLabel = listening ? "Stop dictation" : "Start dictation"
        micButton.isEnabled = state == .idle || listening
        micButton.configuration?.showsActivityIndicator = state != .idle && !listening

        let proxy = textDocumentProxy
        let context = (proxy.documentContextBeforeInput ?? "") + (proxy.documentContextAfterInput ?? "")
        // Match run(_:): a whitespace-only selection falls back to adjacent context.
        let selection = proxy.selectedText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let availableText = selection ?? context
        let hasText = !availableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        fixButton.isEnabled = state == .idle && hasText
        rewriteButton.isEnabled = state == .idle && hasText
        fixButton.accessibilityLabel = selection != nil ? "Fix selected text" : "Fix available text"
        rewriteButton.accessibilityLabel = selection != nil ? "Rewrite selected text" : "Rewrite available text"
        if let selected = proxy.selectedText, !selected.isEmpty {
            preview.text = selected
            preview.textColor = Palette.text
        } else {
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            preview.text = trimmed.isEmpty ? "Dictate into this field." : trimmed
            preview.textColor = trimmed.isEmpty ? Palette.secondary : Palette.text
        }

        switch state {
        case .idle: header.text = message ?? (ready != nil ? "Text ready to insert" : "Ready")
        case .listening: header.text = message ?? "Listening…"
        case .transcribing: header.text = "Processing dictation…"
        case .fixing(let task): header.text = task == .rewrite ? "Rewriting…" : (task == .correct ? "Applying corrections…" : "Fixing text…")
        }
        header.textColor = listening ? Palette.accent : Palette.text
        undoButton.isHidden = lastEdit == nil || state != .idle
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        render()
    }

    private func show(_ message: String?) {
        self.message = message
        render()
    }

    private func feedback(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard AppGroup.defaults.object(forKey: SharedKeys.haptics) as? Bool ?? true else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    // MARK: Typing

    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }

    @objc private func lettersTapped() { lettersShown.toggle() }

    @objc private func deleteHeld(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.textDocumentProxy.deleteBackward() }
            }
        case .ended, .cancelled, .failed:
            deleteTimer?.invalidate()
            deleteTimer = nil
        default: break
        }
    }

    @objc private func insertTapped() {
        guard let ready = hostDictation else { render(); return }
        PendingDictation.current = nil
        insert(dictated: ready.text)
        show("Inserted")
        feedback(.success)
    }

    @objc private func discardTapped() {
        PendingDictation.current = nil
        show(nil)
    }

    @objc private func undoTapped() {
        guard let edit = lastEdit else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        // The host only shares a window of text before the cursor, so a long result may show only its tail;
        // a short context matching the tail could just be earlier text, so it doesn't count.
        let inPlace = before.hasSuffix(edit.result) || (before.count >= 64 && edit.result.hasSuffix(before))
        guard (textDocumentProxy.selectedText ?? "").isEmpty, inPlace else {
            show("Text changed; nothing undone")
            feedback(.warning)
            return
        }
        lastEdit = nil
        for _ in 0..<edit.result.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(edit.original)
        show("Undone")
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
            show("Allow Full Access to dictate")
            feedback(.warning)
            return
        }
        message = nil
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
                case .started: self.show(nil)
                case .level: break
                case .failed(let message):
                    self.state = .idle
                    self.show("Mic: \(message)")
                    self.feedback(.warning)
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
                show("No speech detected")
                feedback(.warning)
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
            defer { if clip.lastPathComponent == "dictation.wav", clip.path.contains("/audio/") { try? FileManager.default.removeItem(at: clip) } }
            do {
                let raw = try await Transcriber.transcribe(clip)
                await self.insertDictation(raw)
            } catch {
                // Speech can be unavailable inside the extension; the app transcribes the same clip.
                NSLog("[DictKB] keyboard transcription failed: \(error)")
                let path = String(clip.path.dropFirst(AppGroup.container.path.count + 1))
                if Bridge.hostIsRunning, let raw = await self.askHost(.transcribe, text: path, timeout: 30), !raw.isEmpty {
                    await self.insertDictation(raw)
                } else {
                    self.state = .idle
                    self.show(error.localizedDescription)
                    self.feedback(.warning)
                }
            }
        }
    }

    private func insertDictation(_ raw: String) async {
        guard AppGroup.defaults.object(forKey: SharedKeys.spokenCorrections) as? Bool ?? true else {
            insert(dictated: raw)
            state = .idle
            return
        }
        let corrected = SpokenCorrections.apply(raw)
        let useModel = AppGroup.defaults.object(forKey: SharedKeys.useModelForCorrections) as? Bool ?? true
        if corrected.needsModel, useModel, Bridge.hostIsAlive {
            state = .fixing(.correct)
            if let text = await askHost(.correct, text: raw, timeout: 30) {
                insert(dictated: text)
                show("Corrected with Gemma")
                state = .idle
                return
            }
        }
        insert(dictated: corrected.text)
        message = corrected.applied > 0 ? "Applied \(corrected.applied) correction\(corrected.applied == 1 ? "" : "s")" : nil
        state = .idle
        feedback(.success)
    }

    private func insert(dictated text: String) {
        guard !text.isEmpty else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        var out = text
        if let last = before.last, !last.isWhitespace, !(textDocumentProxy.selectedText?.isEmpty == false) {
            out = " " + out
        }
        let replaced = textDocumentProxy.selectedText ?? ""
        textDocumentProxy.insertText(out)
        lastEdit = (original: replaced, result: out)
    }

    // MARK: Fix

    @objc private func rewriteTapped() { run(.rewrite) }

    @objc private func fixTapped() { run(.fix) }

    private func run(_ task: BridgeTask) {
        guard state == .idle else { return }
        guard hasFullAccess else {
            show("Allow Full Access to use \(task == .rewrite ? "Rewrite" : "Fix")")
            feedback(.warning)
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
                show("Nothing to \(task == .rewrite ? "rewrite" : "fix") here")
                return
            }
            edit = PendingEdit(id: UUID(), original: text, selection: false, before: before.count, after: after.count, insertion: false)
        }
        message = nil
        state = .fixing(task)
        Task { @MainActor in
            if Bridge.hostIsAlive {
                if let text = await self.askHost(task, text: edit.original, timeout: 120) {
                    if self.apply(edit, text: text) { self.message = task == .rewrite ? "Rewritten" : "Fixed" }
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
                guard let edit = self.pending, !Task.isCancelled else { return }
                // While the app is open the keyboard is off screen, and the text field's context isn't
                // there yet right after it comes back; leave the response for when it can be applied.
                let proxy = self.textDocumentProxy
                let connected = edit.selection || (proxy.documentContextBeforeInput ?? "") + (proxy.documentContextAfterInput ?? "") != ""
                if self.visible, connected, let response = Bridge.takeResponse(edit.id) {
                    self.pending = nil
                    AppGroup.defaults.removeObject(forKey: "pendingEdit")
                    if let text = response.text { if self.apply(edit, text: text) { self.show("Fixed") } }
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
        show(task == .transcribe ? "The app didn't answer" : "Gemma timed out")
        return nil
    }

    /// Replaces the text the edit was made from, only if it is still exactly what's there.
    @discardableResult
    private func apply(_ edit: PendingEdit, text: String) -> Bool {
        let proxy = textDocumentProxy
        if edit.selection {
            guard proxy.selectedText == edit.original else {
                show("Selection changed; nothing replaced")
                feedback(.warning)
                return false
            }
            proxy.insertText(text)
        } else {
            let before = proxy.documentContextBeforeInput ?? ""
            let after = proxy.documentContextAfterInput ?? ""
            guard before + after == edit.original else {
                show("Text changed; nothing replaced")
                feedback(.warning)
                return false
            }
            if !after.isEmpty { proxy.adjustTextPosition(byCharacterOffset: after.count) }
            for _ in 0..<(before.count + after.count) { proxy.deleteBackward() }
            proxy.insertText(text)
        }
        lastEdit = (original: edit.original, result: text)
        feedback(.success)
        return true
    }
}
