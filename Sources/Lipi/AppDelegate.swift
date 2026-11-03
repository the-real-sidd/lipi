import AppKit
import AVFoundation
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let model = AppModel.shared
    private let mic = Mic()
    private let speech = SpeechEngine()
    private let pipeline = Pipeline()
    private let hotkey = Hotkey()
    private let overlay = Overlay()
    private let translatePanel = TranslatePanel()
    private let mainWindow = MainWindowController()
    private let detector = MeetingDetector()
    private lazy var meetingPanel = MeetingPanel(recorder: model.recorder)
    private var statusItem: NSStatusItem!
    private lazy var learner = CorrectionLearner(dictionary: pipeline.dictionary)

    private enum State { case idle, recording, finishing }
    private var state: State = .idle
    private var keepAsSpoken = false
    private var sessionTask: Task<SpeechEngine.Session, Error>?
    private var showOverlayWork: DispatchWorkItem?
    private var pendingProblem: String?
    private var lastRaw = ""
    private var lastTranslated = false
    private var hotkeyTrusted = false
    private let startSound = NSSound(named: "Tink")

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = settings.theme.appearance
        pipeline.dictionary.createIfMissing()
        pipeline.dictionary.reloadIfNeeded()
        speech.contextualWords = pipeline.dictionary.words
        startSound?.volume = 0.2

        buildStatusItem()
        hotkey.handler = { [weak self] in self?.handle($0) }
        applyKeys()
        hotkey.start()
        hotkeyTrusted = Inserter.isTrusted
        watchForAccessibility()

        model.onChange = { [weak self] in self?.settingsChanged() }
        model.onStartNotes = { [weak self] in self?.startNotes(appName: nil) }
        model.onStopNotes = { [weak self] in self?.stopNotes() }
        model.recorder.onFinished = { [weak self] in self?.notesSaved($0) }
        setUpMeetings()

        mic.select(deviceUID: settings.inputDeviceUID)
        mic.prepare()

        learner.onLearned = { [weak self] message in self?.overlay.flash(message, seconds: 2.2) }
        learner.onDictionaryChanged = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .lipiDictionaryChanged, object: nil)
            self.speech.contextualWords = self.pipeline.dictionary.words
            self.speech.resetStandby()
            Task { await self.speech.prepareStandby(self.settings.speechLocale) }
        }

        let quiet = launchedAsLoginItem
        Task {
            await model.refresh()
            if !quiet || !model.isReady { mainWindow.show(.home) }
            await warmUp()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.write("reopen")
        mainWindow.show()
        return false
    }

    /// Opening Lipi from Finder, Spotlight or the Dock shows the window. Only a login-item launch stays quiet.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private var spoken: String { LanguageCatalog.languageCode(ofLocale: settings.speechLocale) }

    /// Loads every model before the first dictation so the first one is as fast as the rest.
    private func warmUp() async {
        let clock = Clock()
        await speech.prepareStandby(settings.speechLocale)
        if let target = dictationTarget(keep: false) { await pipeline.translator.warmUp(from: spoken, to: target) }
        if settings.smartCleanup { pipeline.polisher.prewarm() }
        Log.write("warm-up done in \(clock.ms) ms")
    }

    private func settingsChanged() {
        applyKeys()
        if Inserter.isTrusted && !hotkeyTrusted {
            hotkeyTrusted = true
            hotkey.start() // global key monitors only work once Accessibility is on
        }
        mic.select(deviceUID: settings.inputDeviceUID)
        mic.prepare()
        speech.resetStandby()
        pipeline.translator.reset()
        Task { await warmUp() }
    }

    private var trustTimer: Timer?

    /// Checks every 2 s until Accessibility is granted, then re-arms the shortcuts. Global key
    /// monitors installed before the grant never fire, so this saves a restart.
    private func watchForAccessibility() {
        guard trustTimer == nil, !Inserter.isTrusted else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, Inserter.isTrusted else { return }
                timer.invalidate()
                self.trustTimer = nil
                self.hotkeyTrusted = true
                self.hotkey.start()
                self.overlay.flash("Lipi can type for you now", seconds: 1.8)
                Log.write("accessibility granted, shortcuts re-armed")
            }
        }
    }

    private func applyKeys() {
        hotkey.dictationKey = settings.dictationKey
        hotkey.translateKey = settings.translateKey
    }

    private func dictationTarget(keep: Bool) -> String? {
        let out = settings.outputLanguage
        if keep || out.isEmpty || out == spoken { return nil }
        return out
    }

    private func short(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func modeLabel() -> String {
        if let target = dictationTarget(keep: keepAsSpoken) { return "\(short(spoken)) → \(short(target))" }
        return short(spoken)
    }

    // MARK: Gestures

    private func handle(_ gesture: Hotkey.Gesture) {
        switch gesture {
        case .holdBegan(let keep): beginRecording(keep: keep)
        case .modeChanged(let keep):
            guard state == .recording else { return }
            keepAsSpoken = keep
            overlay.model.mode = modeLabel()
        case .holdEnded: finishRecording()
        case .tapped, .cancelled: cancelRecording()
        case .doubleTapped: Task { await translateSelection() }
        }
    }

    private func beginRecording(keep: Bool) {
        guard state == .idle else { return }
        learner.check(final: true)
        pendingProblem = nil
        keepAsSpoken = keep
        let locale = settings.speechLocale
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            pendingProblem = "Allow the microphone in Lipi settings."
            return
        }
        guard let format = speech.cachedFormat(for: locale) else {
            pendingProblem = "Download the \(LanguageCatalog.name(locale)) speech model in Lipi settings."
            return
        }
        let stream: AsyncStream<AnalyzerInput>
        do {
            stream = try mic.start(format: format)
        } catch {
            pendingProblem = "Couldn't start the microphone."
            return
        }
        state = .recording
        mic.onLevel = { [weak self] level in self?.overlay.model.level = level }
        sessionTask = Task { [speech, overlay, pipeline] in
            try await speech.begin(locale, input: stream, onPartial: { [weak self] text in
                overlay.model.text = text
                guard let self else { return }
                pipeline.prefetch(text, speechLocale: locale, target: self.dictationTarget(keep: self.keepAsSpoken))
            })
        }
        // Wait a moment before showing anything, so a quick tap doesn't flash the overlay.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .recording else { return }
            self.overlay.show(.listening, mode: self.modeLabel(), text: "")
            if self.settings.playSounds { self.startSound?.stop(); self.startSound?.play() }
            self.setIcon(active: true)
        }
        showOverlayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func cancelRecording() {
        pendingProblem = nil
        guard state == .recording else { return }
        state = .idle
        showOverlayWork?.cancel()
        mic.stop()
        overlay.hide()
        setIcon(active: model.recorder.isRecording)
        if let task = sessionTask {
            Task { [speech, settings] in
                if let session = try? await task.value { await speech.cancel(session) }
                await speech.prepareStandby(settings.speechLocale)
            }
        }
        sessionTask = nil
    }

    private func finishRecording() {
        if let problem = pendingProblem {
            pendingProblem = nil
            overlay.flash(problem, isError: true)
            mainWindow.show(.settings)
            return
        }
        guard state == .recording, let task = sessionTask else { return }
        state = .finishing
        sessionTask = nil
        showOverlayWork?.cancel()
        let released = Clock()
        mic.stop()
        setIcon(active: model.recorder.isRecording)
        overlay.show(.working, mode: modeLabel())
        let locale = settings.speechLocale
        let target = dictationTarget(keep: keepAsSpoken)
        let category = StyleEngine.currentCategory()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName

        Task {
            defer {
                state = .idle
                Task { await speech.prepareStandby(settings.speechLocale) }
            }
            guard let session = try? await task.value else {
                overlay.flash("The speech model isn't ready. Open Lipi settings.", isError: true)
                return
            }
            let raw = await speech.finish(session)
            let speechMs = released.ms
            if pipeline.dictionary.reloadIfNeeded() {
                speech.contextualWords = pipeline.dictionary.words
                speech.resetStandby()
            }
            let output = await pipeline.produce(raw, speechLocale: locale, target: target, category: category)
            lastRaw = raw
            lastTranslated = pipeline.lastTiming.translateMs > 0
            deliver(output, app: appName, ms: released.ms)
            Log.write("dictation \(locale)→\(target ?? "same") style=\(category.rawValue) chars=\(raw.count) speech_tail_ms=\(speechMs) translate_ms=\(pipeline.lastTiming.translateMs) polish_ms=\(pipeline.lastTiming.polishMs) release_to_text_ms=\(released.ms)")
        }
    }

    private func deliver(_ output: Pipeline.Output, app: String?, ms: Int) {
        switch output {
        case .empty:
            overlay.flash("Didn't catch that. Try again a little closer to the mic.")
        case .undo:
            Inserter.undo()
            overlay.flash("Undid the last dictation")
        case .text(let text, let note):
            History.shared.add(DictationRecord(kind: .dictation, text: text, app: app, milliseconds: ms))
            if NSApp.isActive {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                overlay.flash("Click into a text box in another app first. Your text is copied.", isError: true, seconds: 3.5)
                return
            }
            let outcome = Inserter.insert(Inserter.spacedForCursor(text))
            if outcome == .pasted { learner.begin(inserted: text, source: lastRaw, translated: lastTranslated) }
            if outcome == .copiedOnly {
                overlay.flash("Your text is copied. Lipi needs Accessibility to type it for you: open Lipi → Settings → Permissions.", isError: true, seconds: 5)
                watchForAccessibility()
            } else if let note {
                overlay.flash(note, isError: true, seconds: 4)
            } else {
                overlay.show(.done, text: text)
                overlay.hide(after: 0.45)
            }
        }
    }

    // MARK: Translate selection

    private func translateSelection() async {
        guard state == .idle else { return }
        guard Inserter.isTrusted else {
            overlay.flash("Lipi needs Accessibility to read selected text: open Lipi → Settings → Permissions.", isError: true, seconds: 5)
            watchForAccessibility()
            mainWindow.show(.settings)
            return
        }
        guard let text = await Inserter.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            overlay.flash("Select some text first, then double-tap \(settings.translateKey.symbol).")
            return
        }
        let source = settings.selectionSource == "auto" ? (LanguageCatalog.detect(text) ?? spoken) : settings.selectionSource
        var target = settings.selectionTarget
        if source == target { target = spoken != target ? spoken : (target == "en" ? "hi" : "en") }

        let panelModel = translatePanel.model
        panelModel.targetLanguage = target
        translatePanel.show(source: text, direction: "\(short(source)) → \(short(target))")
        let clock = Clock()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        do {
            let result = try await pipeline.translator.translate(text, from: source, to: target)
            translatePanel.update(result: result, error: nil)
            panelModel.onReplace = { [weak self] in
                self?.translatePanel.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Inserter.insert(result) }
            }
            panelModel.onCopy = { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                self?.translatePanel.close()
                self?.overlay.flash("Copied", seconds: 1.2)
            }
            History.shared.add(DictationRecord(kind: .translation, text: result, app: appName, milliseconds: clock.ms))
        } catch {
            Log.write("translate selection failed: \(error.localizedDescription)")
            translatePanel.update(result: nil, error: "The \(short(source)) → \(short(target)) translation isn't downloaded yet. Open Lipi → Settings → Languages.")
        }
        Log.write("translate selection \(source)→\(target) chars=\(text.count) ms=\(clock.ms)")
    }

    // MARK: Meetings

    private func setUpMeetings() {
        let panel = meetingPanel.model
        panel.onStart = { [weak self] in self?.startNotes(appName: self?.detector.active?.name) }
        panel.onDismiss = { [weak self] in self?.meetingPanel.hide() }
        panel.onStop = { [weak self] in self?.stopNotes() }
        panel.onAddPointer = { [weak self] in self?.model.recorder.addPointer($0) }
        panel.onOpen = { [weak self] in self?.meetingPanel.hide(); self?.mainWindow.show(.notes) }

        detector.onStart = { [weak self] app in
            guard let self, self.settings.meetingAutoDetect, !self.model.recorder.isRecording else { return }
            self.meetingPanel.show(.offer(app.name), hideAfter: 60)
            if self.settings.playSounds { NSSound(named: "Glass")?.play() }
        }
        detector.onEnd = { [weak self] _ in
            guard let self else { return }
            if self.model.recorder.isRecording && self.settings.meetingAutoStop {
                self.stopNotes()
            } else if !self.model.recorder.isRecording {
                self.meetingPanel.hide()
            }
        }
        detector.start()
    }

    private func startNotes(appName: String?) {
        guard !model.recorder.isRecording else { return }
        meetingPanel.hide()
        // If a call app is already using the mic, follow it so notes stop when it ends.
        let current = detector.active ?? AudioDevices.processesUsingMicrophone().compactMap { MeetingDetector.meetingApp(for: $0.bundle) }.first
        if let current { detector.adopt(current) }
        let name = appName ?? current?.name ?? "Meeting"
        Task {
            do {
                try await model.recorder.start(app: name, locale: settings.meetingLocale, micUID: settings.inputDeviceUID)
                meetingPanel.show(.recording)
                setIcon(active: true)
            } catch {
                overlay.flash(error.localizedDescription, isError: true, seconds: 4)
                mainWindow.show(.settings)
            }
        }
    }

    private func stopNotes() {
        guard model.recorder.isRecording else { return }
        detector.release()
        Task { await model.recorder.stop() }
    }

    private func notesSaved(_ meeting: Meeting) {
        setIcon(active: false)
        meetingPanel.show(.saved(meeting.title), hideAfter: 10)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(active: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func setIcon(active: Bool) {
        let name = active ? "waveform.circle.fill" : "character.bubble"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Lipi")
        image?.isTemplate = !active
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = active ? .systemOrange : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(info(model.isReady ? "Lipi is ready" : "Lipi needs setup"))
        menu.addItem(info("Hold \(settings.dictationKey.symbol) to speak · \(modeLabel())"))
        menu.addItem(info("Double-tap \(settings.translateKey.symbol) to translate selection"))
        menu.addItem(.separator())
        if model.recorder.isRecording {
            menu.addItem(action("Stop Taking Notes", #selector(menuStopNotes), key: ""))
        } else {
            menu.addItem(action("Start Taking Notes", #selector(menuStartNotes), key: ""))
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Lipi…", #selector(openMain), key: "o"))
        menu.addItem(action("Notes…", #selector(openNotes), key: "n"))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit Lipi", #selector(quit), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuStartNotes() { startNotes(appName: nil) }
    @objc private func menuStopNotes() { stopNotes() }
    @objc private func openMain() { mainWindow.show(.home) }
    @objc private func openNotes() { mainWindow.show(.notes) }
    @objc private func openSettings() { mainWindow.show(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }
}
