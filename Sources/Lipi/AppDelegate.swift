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
    private var mode: DictationMode = .asSpoken
    private var locked = false
    private var sessionTask: Task<SpeechEngine.Session, Error>?
    private var showOverlayWork: DispatchWorkItem?
    private var handsFreeLimit: DispatchWorkItem?
    private var pendingProblem: String?
    private var lastRaw = ""
    private var lastTranslated = false
    private var hotkeyTrusted = false
    private let startSound = NSSound(named: "Tink")
    private let lockSound = NSSound(named: "Pop")

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = settings.theme.appearance
        settings.resolveShortcutClashes()
        pipeline.dictionary.createIfMissing()
        pipeline.dictionary.reloadIfNeeded()
        speech.contextualWords = pipeline.dictionary.words
        startSound?.volume = 0.2
        lockSound?.volume = 0.25

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
        if settings.testHooks { installTestHooks() }

        let quiet = launchedAsLoginItem
        Task {
            await model.refresh()
            if !quiet || !model.isReady { mainWindow.show(.home) }
            await warmUp()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    /// Opening Lipi again from Finder, Spotlight or Launchpad activates the running copy.
    /// Menu-bar apps don't always get a "reopen" event for that, so show the window here.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard launchedAt.timeIntervalSinceNow < -2, !mainWindow.isVisible, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        mainWindow.show()
    }
    private let launchedAt = Date()

    /// Opening Lipi from Finder, Spotlight or the Dock shows the window. Only a login-item launch stays quiet.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private var spoken: String { LanguageCatalog.languageCode(ofLocale: settings.speechLocale) }
    private var translateTarget: String { settings.outputLanguage.nonEmpty ?? "en" }

    /// Loads every model before the first dictation so the first one is as fast as the rest.
    private func warmUp() async {
        let clock = Clock()
        await speech.prepareStandby(settings.speechLocale)
        if spoken != translateTarget { await pipeline.translator.warmUp(from: spoken, to: translateTarget) }
        if settings.smartCleanup { pipeline.polisher.prewarm() }
        AIService.shared.warmUp()
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
        hotkey.keys = .init(asSpoken: settings.dictationKey, translate: settings.translateDictationKey, selection: settings.translateKey)
    }

    private func short(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func modeLabel() -> String {
        let base = mode == .translate && spoken != translateTarget ? "\(short(spoken)) → \(short(translateTarget))" : short(spoken)
        let ai = AIService.shared.isEnabled ? " · AI" : ""
        if locked {
            let key = mode == .translate ? settings.translateDictationKey.symbol : settings.dictationKey.symbol
            return "Hands-free · \(base)\(ai) · tap \(key) to finish"
        }
        return base + ai
    }

    // MARK: Gestures

    private func handle(_ output: GestureMachine.Output) {
        switch output {
        case .start(let m): beginRecording(m)
        case .lock: lockRecording()
        case .finish: finishRecording()
        case .cancel: cancelRecording()
        case .translateSelection: Task { await translateSelection() }
        }
    }

    private func beginRecording(_ newMode: DictationMode) {
        guard state == .idle else { return }
        learner.check(final: true)
        pendingProblem = nil
        mode = newMode
        locked = false
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
        let currentMode = newMode
        sessionTask = Task { [speech, overlay, pipeline] in
            try await speech.begin(locale, input: stream, onPartial: { text in
                overlay.model.text = text
                pipeline.prefetch(text, speechLocale: locale, mode: currentMode)
            })
        }
        AIService.shared.warmUp()
        // Show the overlay only once it's clearly a hold, so a quick tap doesn't flash it.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .recording, self.hotkey.isHolding || self.locked else { return }
            self.showListening()
        }
        showOverlayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func showListening() {
        overlay.show(.listening, mode: modeLabel(), text: overlay.model.text)
        if settings.playSounds { startSound?.stop(); startSound?.play() }
        setIcon(active: true)
    }

    /// Double-tap: keep listening until the key is tapped again.
    private func lockRecording() {
        guard state == .recording else {
            if let problem = pendingProblem { pendingProblem = nil; overlay.flash(problem, isError: true); mainWindow.show(.settings) }
            return
        }
        locked = true
        showOverlayWork?.cancel()
        showListening()
        if settings.playSounds { lockSound?.play() }
        // Safety net: hands-free stops on its own after 10 minutes.
        let limit = DispatchWorkItem { [weak self] in
            guard let self, self.locked, self.state == .recording else { return }
            self.hotkey.reset()
            self.finishRecording()
        }
        handsFreeLimit?.cancel()
        handsFreeLimit = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: limit)
    }

    private func cancelRecording() {
        pendingProblem = nil
        handsFreeLimit?.cancel()
        locked = false
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
        handsFreeLimit?.cancel()
        if let problem = pendingProblem {
            pendingProblem = nil
            overlay.flash(problem, isError: true)
            mainWindow.show(.settings)
            return
        }
        guard state == .recording, let task = sessionTask else { return }
        state = .finishing
        locked = false
        sessionTask = nil
        showOverlayWork?.cancel()
        let released = Clock()
        mic.stop()
        setIcon(active: model.recorder.isRecording)
        overlay.show(.working, mode: modeLabel())
        let locale = settings.speechLocale
        let currentMode = mode
        let category = StyleEngine.currentCategory()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        let setupMs = released.ms

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
            let tReload = released.ms
            let output = await pipeline.produce(raw, speechLocale: locale, mode: currentMode, category: category)
            let tProduce = released.ms
            lastRaw = raw
            lastTranslated = currentMode == .translate
            deliver(output, app: appName, ms: released.ms, raw: raw)
            let t = pipeline.lastTiming
            Log.write("dictation \(locale) mode=\(currentMode) style=\(category.rawValue) chars=\(raw.count) ai=\(t.usedAI) speech_tail_ms=\(speechMs) reload_at=\(tReload) produce_at=\(tProduce) ai_ms=\(t.aiMs) translate_ms=\(t.translateMs) polish_ms=\(t.polishMs) release_to_text_ms=\(released.ms) setup_ms=\(setupMs)")
        }
    }

    private func deliver(_ output: Pipeline.Output, app: String?, ms: Int, raw: String) {
        switch output {
        case .empty:
            overlay.flash("Didn't catch that. Try again a little closer to the mic.")
            reportTest(raw: raw, output: "", pasted: false, ms: ms)
        case .undo:
            Inserter.undo()
            overlay.flash("Undid the last dictation")
        case .text(let text, let note, let send):
            if !settings.testHooks {
                History.shared.add(DictationRecord(kind: mode == .translate ? .translation : .dictation, text: text, app: app, milliseconds: ms))
            }
            if NSApp.isActive && !settings.testHooks {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                overlay.flash("Click into a text box in another app first. Your text is copied.", isError: true, seconds: 3.5)
                return
            }
            let outcome = Inserter.insert(Inserter.spacedForCursor(text))
            if outcome == .pasted {
                learner.begin(inserted: text, source: lastRaw, translated: lastTranslated)
                if send { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Inserter.pressReturn() } }
            }
            reportTest(raw: raw, output: text, pasted: outcome == .pasted, ms: ms)
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
        var result: String?
        if AIService.shared.isEnabled {
            result = try? await AIWriter.translateSelection(text, to: target)
        }
        if result == nil {
            do {
                let input = source == "hi" && LanguageCatalog.isLatin(text) ? Pipeline.normalizeHinglish(text) : text
                result = try await pipeline.translator.translate(input, from: source, to: target)
            } catch {
                Log.write("translate selection failed: \(error.localizedDescription)")
            }
        }
        guard let result else {
            translatePanel.update(result: nil, error: "The \(short(source)) → \(short(target)) translation isn't downloaded yet. Open Lipi → Settings → Languages.")
            return
        }
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
        Log.write("translate selection \(source)→\(target) chars=\(text.count) ms=\(clock.ms)")
    }

    // MARK: Test hooks (developer only: `defaults write app.lipi.mac testHooks -bool YES`)

    /// Lets the test harness run the real dictation path with an audio file in place of the mic:
    /// same recorder, pipeline, paste and focused app. Results go to ~/Library/Logs/Lipi-test.json.
    private func installTestHooks() {
        DistributedNotificationCenter.default().addObserver(forName: .init("app.lipi.test"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo as? [String: Any] ?? [:]
            MainActor.assumeIsolated { self?.runTest(info) }
        }
        Log.write("test hooks on")
    }

    private func runTest(_ info: [String: Any]) {
        if info["action"] as? String == "micCheck" { runMicCheck(); return }
        guard let path = info["file"] as? String, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        mic.fakeFile = URL(fileURLWithPath: path)
        let action = info["action"] as? String ?? "dictate"
        let handsFree = info["handsFree"] as? Bool == true
        if info["keys"] as? Bool == true {
            // Real keyboard path: post the same key events your finger would.
            let key = action == "translate" ? settings.translateDictationKey : settings.dictationKey
            Task { @MainActor in
                if handsFree {
                    Inserter.postModifier(key, down: true); try? await Task.sleep(for: .milliseconds(80))
                    Inserter.postModifier(key, down: false); try? await Task.sleep(for: .milliseconds(120))
                    Inserter.postModifier(key, down: true); try? await Task.sleep(for: .milliseconds(80))
                    Inserter.postModifier(key, down: false)
                    try? await Task.sleep(for: .seconds(duration + 0.3))
                    Inserter.postModifier(key, down: true); try? await Task.sleep(for: .milliseconds(60))
                    Inserter.postModifier(key, down: false)
                } else {
                    Inserter.postModifier(key, down: true)
                    try? await Task.sleep(for: .seconds(duration + 0.3))
                    Inserter.postModifier(key, down: false)
                }
                try? await Task.sleep(for: .seconds(1))
                self.mic.fakeFile = nil
            }
            return
        }
        handle(.start(action == "translate" ? .translate : .asSpoken))
        if handsFree { handle(.lock(mode)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) { [weak self] in
            self?.handle(.finish)
            self?.mic.fakeFile = nil
        }
    }

    /// Opens the real microphone the normal way, then checks it was the built-in mic and that it
    /// was fully released afterwards (so Bluetooth headphones stay in music mode).
    private func runMicCheck() {
        let me = ProcessInfo.processInfo.processIdentifier
        func usingMic() -> Bool { AudioDevices.processesUsingMicrophone(includeSelf: true).contains { $0.pid == me } }
        let before = usingMic()
        Task { @MainActor in
            var report: [String: Any] = ["action": "micCheck", "openBefore": before, "outBefore": AudioDevices.outputSampleRate(),
                                         "auth": AVCaptureDevice.authorizationStatus(for: .audio).rawValue, "timing": mic.debugTiming]
            guard let format = await speech.format(for: settings.speechLocale) else { return }
            do {
                let stream = try mic.start(format: format)
                report["startMs"] = mic.lastStartMs
                report["timing"] = mic.debugTiming
                var frames = 0
                let reader = Task { for await _ in stream { frames += 1 } }
                try? await Task.sleep(for: .seconds(1))
                report["openDuring"] = usingMic()
                report["outDuring"] = AudioDevices.outputSampleRate()
                mic.stop()
                await reader.value
                report["buffers"] = frames
                try? await Task.sleep(for: .milliseconds(600))
                report["openAfter"] = usingMic()
                report["outAfter"] = AudioDevices.outputSampleRate()
                report["builtIn"] = AudioDevices.builtInName() ?? "none"
            } catch {
                report["error"] = error.localizedDescription
            }
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lipi-test.json")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) { try? data.write(to: url) }
        }
    }

    private func reportTest(raw: String, output: String, pasted: Bool, ms: Int) {
        guard settings.testHooks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [pipeline] in
            let report: [String: Any] = [
                "raw": raw, "output": output, "pasted": pasted, "ms": ms,
                "usedAI": pipeline.lastTiming.usedAI, "aiMs": pipeline.lastTiming.aiMs,
                "field": Inserter.focusedValue() ?? "", "app": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            ]
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lipi-test.json")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) { try? data.write(to: url) }
        }
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
        menu.addItem(info("Hold \(settings.dictationKey.symbol) · type as you speak"))
        menu.addItem(info("Hold \(settings.translateDictationKey.symbol) · speak and translate to \(short(translateTarget))"))
        menu.addItem(info("Double-tap either to go hands-free"))
        menu.addItem(info("Double-tap \(settings.translateKey.symbol) · translate selected text"))
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
