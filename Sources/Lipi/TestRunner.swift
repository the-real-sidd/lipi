import AppKit
import AVFoundation
import FoundationModels
import Speech

/// Command-line tools and test suites. Run `Lipi --help`.
@MainActor
enum TestRunner {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let locale = value("--locale") ?? "hi-IN"

        switch args.first {
        case "--status":
            for l in Set([locale, "hi-IN", "en-IN"]).sorted() { print("speech \(l): \(await SpeechEngine.status(l))") }
            for (a, b) in [("hi", "en"), ("en", "hi")] { print("translation \(a)->\(b): \(await Translator.status(from: a, to: b))") }
            print("apple intelligence: \(SystemLanguageModel.default.availability)")
            print("AI mode: \(AIService.shared.isEnabled ? "on (\(Settings.shared.aiModel))" : "off")")
            return 0

        case "--install":
            let l = value("--install") ?? "hi-IN"
            do {
                try await SpeechEngine.install(l) { _ in }
                print("installed \(l) -> \(await SpeechEngine.status(l))")
                return 0
            } catch { print("install failed: \(error)"); return 1 }

        case "--clean": print(TextCleanup.clean(value("--clean") ?? "", language: value("--lang") ?? "en")); return 0
        case "--numbers": print(NumberWords.digitize(value("--numbers") ?? "")); return 0
        case "--detect": print(LanguageCatalog.detect(value("--detect") ?? "") ?? "unknown"); return 0
        case "--style":
            print(StyleEngine.apply(WritingStyle(rawValue: value("--as") ?? "casual") ?? .casual, to: value("--style") ?? ""))
            return 0

        case "--translate":
            let text = value("--translate") ?? ""
            let from = (value("--from") ?? "auto") == "auto" ? (LanguageCatalog.detect(text) ?? "hi") : value("--from")!
            do {
                let clock = Clock()
                let out = try await Translator().translate(Pipeline.normalizeHinglish(text), from: from, to: value("--to") ?? "en")
                print("\(from)->\(value("--to") ?? "en") (\(clock.ms) ms): \(out)")
                return 0
            } catch { print("translate failed: \(error)"); return 1 }

        case "--ai-models":
            guard let key = Keychain.read() else { print("no key"); return 1 }
            do { for m in try await AIService.shared.availableModels(key: key) where m.contains("flash") || m.contains("pro") { print(m) } }
            catch { print("error: \(error.localizedDescription)") }
            return 0

        case "--ai-bench":
            let saved = Settings.shared.aiModel
            defer { Settings.shared.aiModel = saved }
            for model in args.dropFirst() {
                Settings.shared.aiModel = model
                var times: [Int] = []
                var sample = ""
                for text in ["bhai kal office nahin aa paunga Tabiat thodi kharab Hai", "kya tum aaj raat ko free ho movie Dekhne chale",
                             "aap report aaj Shaam tak Bhej sakte hain kya", "meeting ko Friday ko shift kar do nahi nahi Monday ko"] {
                    let c = Clock()
                    if let out = try? await AIWriter.translate(text, from: "hi", to: "en", words: []) { times.append(c.ms); if sample.isEmpty { sample = out } }
                    else { times.append(-1) }
                }
                print("\(model): \(times.map(String.init).joined(separator: ", ")) ms  e.g. \(sample)")
            }
            return 0

        case "--ai":
            // --ai clean|translate TEXT
            let kind = value("--ai") ?? "clean"
            guard args.count > 2 else { return 1 }
            let text = args[2]
            let clock = Clock()
            do {
                let out = kind == "translate"
                    ? try await AIWriter.translate(text, from: LanguageCatalog.detect(text) ?? "hi", to: "en", words: [])
                    : try await AIWriter.clean(text, language: LanguageCatalog.languageCode(ofLocale: locale), words: [])
                print("(\(clock.ms) ms) \(out)")
                return 0
            } catch { print("AI failed: \(error.localizedDescription)"); return 1 }

        case "--transcribe":
            guard let path = value("--transcribe") else { return 1 }
            let mode: DictationMode = (value("--mode") ?? "spoken") == "translate" ? .translate : .asSpoken
            guard let r = await transcribe(path: path, locale: locale, mode: mode, realtime: args.contains("--realtime")) else { return 1 }
            print("heard: \(r.raw)\ntyped: \(r.output)\nrelease→text: \(r.ms) ms (ai \(r.usedAI))")
            return 0

        case "--test-gestures": return GestureTests.run()
        case "--test-text": return TextTests.run()
        case "--test-audio": return await AudioTests.run(includeAI: args.contains("--ai-only") || AIService.shared.isEnabled, onlyAI: args.contains("--ai-only"))
        case "--test-e2e": return await EndToEnd.run(keys: args.contains("--keys"))

        case "--mic-users":
            for p in AudioDevices.processesUsingMicrophone() {
                print("\(p.pid) \(p.bundle) -> \(MeetingDetector.meetingApp(for: p.bundle)?.name ?? "not a meeting app")")
            }
            return 0

        case "--summarize":
            guard let path = value("--summarize"), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 1 }
            var meeting = Meeting(title: "Test", app: "Zoom", start: Date().addingTimeInterval(-1500), locale: value("--locale") ?? "en-IN")
            meeting.end = Date()
            for (i, line) in text.components(separatedBy: .newlines).enumerated() where line.contains(":") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                meeting.segments.append(.init(speaker: parts[0].lowercased() == "me" ? .me : .others, at: Double(i * 20), text: parts[1]))
            }
            print(await Summarizer.summarize(meeting))
            return 0

        default:
            print("""
            Lipi --status | --install hi-IN | --mic-users
            Lipi --test-gestures | --test-text | --test-audio [--ai-only] | --test-e2e [--keys]
            Lipi --transcribe FILE [--locale hi-IN] [--mode spoken|translate] [--realtime]
            Lipi --ai clean|translate TEXT [--locale hi-IN]
            Lipi --translate TEXT [--from auto] [--to en] | --clean TEXT | --numbers TEXT | --style TEXT --as casual
            """)
            return 0
        }
    }

    struct Result { let raw: String; let output: String; let send: Bool; let ms: Int; let usedAI: Bool }

    /// Plays a file through the live pipeline. With `realtime` the audio is fed at speaking speed,
    /// so the release→text time is the one you'd feel in the app.
    static func transcribe(path: String, locale: String, mode: DictationMode, realtime: Bool,
                           speech givenSpeech: SpeechEngine? = nil, pipeline givenPipeline: Pipeline? = nil) async -> Result? {
        let speech = givenSpeech ?? SpeechEngine()
        let pipeline = givenPipeline ?? Pipeline()
        guard let format = await speech.format(for: locale) else { print("speech model for \(locale) not installed"); return nil }
        await speech.prepareStandby(locale)
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { print("can't open \(path)"); return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let converter = StreamConverter(output: format)
        guard let session = try? await speech.begin(locale, input: stream, onPartial: { text in
            pipeline.prefetch(text, speechLocale: locale, mode: mode)
        }) else { return nil }
        let chunk: AVAudioFrameCount = 2048
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil else { break }
            if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
            if realtime { try? await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate)) }
        }
        let released = Clock()
        continuation.finish()
        let raw = await speech.finish(session)
        let output = await pipeline.produce(raw, speechLocale: locale, mode: mode, category: .other)
        switch output {
        case .text(let t, _, let send): return Result(raw: raw, output: t, send: send, ms: released.ms, usedAI: pipeline.lastTiming.usedAI)
        case .undo: return Result(raw: raw, output: "<undo>", send: false, ms: released.ms, usedAI: false)
        case .empty: return Result(raw: raw, output: "", send: false, ms: released.ms, usedAI: false)
        }
    }
}

/// Tiny assertion helper shared by the suites.
struct Checker {
    var passed = 0
    var failed: [String] = []
    mutating func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") } else { failed.append(name); print("  ✗ \(name)  \(detail())") }
    }
    func finish(_ suite: String) -> Int32 {
        print("\(suite): \(passed) passed, \(failed.count) failed")
        return failed.isEmpty ? 0 : 1
    }
}

// MARK: - Gestures

@MainActor
enum GestureTests {
    static func run() -> Int32 {
        var c = Checker()
        let keys = GestureMachine.Keys(asSpoken: .rightOption, translate: .rightCommand, selection: .leftOption)
        func play(_ events: [GestureMachine.Event]) -> [GestureMachine.Output] {
            var m = GestureMachine(keys: keys)
            return events.flatMap { m.handle($0) }
        }
        let o = TriggerKey.rightOption, cmd = TriggerKey.rightCommand, sel = TriggerKey.leftOption

        c.check(play([.down(o, 0, otherModifiers: false), .up(o, 1.5)]) == [.start(.asSpoken), .finish], "hold Right ⌥ → dictate as spoken")
        c.check(play([.down(cmd, 0, otherModifiers: false), .up(cmd, 2)]) == [.start(.translate), .finish], "hold Right ⌘ → dictate and translate")
        c.check(play([.down(o, 0, otherModifiers: false), .up(o, 0.1), .tick(0.6)]) == [.start(.asSpoken), .cancel], "single quick tap cancels silently")
        c.check(play([.down(o, 0, otherModifiers: false), .up(o, 0.1), .down(o, 0.3, otherModifiers: false), .up(o, 0.4)])
                == [.start(.asSpoken), .lock(.asSpoken)], "double-tap → hands-free lock")
        c.check(play([.down(o, 0, otherModifiers: false), .up(o, 0.1), .down(o, 0.3, otherModifiers: false), .up(o, 0.4),
                      .otherKey(escape: false, 3), .down(o, 9, otherModifiers: false), .up(o, 9.1)])
                == [.start(.asSpoken), .lock(.asSpoken), .finish], "hands-free keeps going while typing, tap again finishes")
        c.check(play([.down(cmd, 0, otherModifiers: false), .up(cmd, 0.1), .down(cmd, 0.25, otherModifiers: false), .up(cmd, 0.3),
                      .down(cmd, 5, otherModifiers: false), .up(cmd, 5.05)])
                == [.start(.translate), .lock(.translate), .finish], "hands-free translate")
        c.check(play([.down(o, 0, otherModifiers: false), .up(o, 0.1), .down(o, 0.3, otherModifiers: false), .up(o, 0.35), .otherKey(escape: true, 2)])
                == [.start(.asSpoken), .lock(.asSpoken), .cancel], "Esc cancels hands-free")
        c.check(play([.down(o, 0, otherModifiers: false), .otherKey(escape: false, 0.2), .up(o, 0.3)])
                == [.start(.asSpoken), .cancel], "⌥ + a letter (special character) cancels, no text")
        c.check(play([.down(o, 0, otherModifiers: true), .up(o, 1)]) == [], "⌥ pressed during another shortcut is ignored")
        c.check(play([.down(o, 0, otherModifiers: false), .otherModifier(0.3), .up(o, 1)]) == [.start(.asSpoken), .cancel], "adding ⌘/⇧ turns it into a shortcut, cancels")
        c.check(play([.down(sel, 0, otherModifiers: false), .up(sel, 0.08), .down(sel, 0.25, otherModifiers: false), .up(sel, 0.3)])
                == [.translateSelection], "double-tap Left ⌥ → translate selection")
        c.check(play([.down(sel, 0, otherModifiers: false), .up(sel, 0.08), .down(sel, 2, otherModifiers: false), .up(sel, 2.1)]) == [],
                "two slow taps of Left ⌥ do nothing")
        c.check(play([.down(sel, 0, otherModifiers: false), .up(sel, 1)]) == [], "holding Left ⌥ does nothing")
        c.check(play([.down(o, 0, otherModifiers: false), .up(o, 0.1), .down(cmd, 0.2, otherModifiers: false), .up(cmd, 2)])
                == [.start(.asSpoken), .cancel, .start(.translate), .finish], "tap one key then hold the other switches mode cleanly")
        c.check(play([.down(o, 0, otherModifiers: false), .up(o, 0.26)]) == [.start(.asSpoken), .finish], "a short but deliberate hold still types")
        return c.finish("Gesture tests")
    }
}

// MARK: - Text rules

@MainActor
enum TextTests {
    static func run() -> Int32 {
        var c = Checker()
        func eq(_ got: String, _ want: String, _ name: String) { c.check(got == want, name, "got: \(got.debugDescription)") }

        eq(TextCleanup.clean("Um, so I was, uh, thinking we could ship it on Friday.", language: "en"), "So I was, thinking we could ship it on Friday.", "English fillers removed")
        eq(TextCleanup.clean("Hmm okay, er, let's go", language: "en"), "Okay, let's go", "hmm/er removed")
        eq(TextCleanup.clean("I I think the the plan works", language: "en"), "I think the plan works", "stutters removed")
        eq(TextCleanup.clean("dheere dheere aa jao", language: "hi"), "Dheere dheere aa jao", "Hinglish repeats and 'aa' kept")
        eq(TextCleanup.clean("hello new line how are you", language: "en"), "Hello\n\nHow are you", "'new line' leaves a blank line")
        eq(TextCleanup.clean("that was amazing laughing emoji", language: "en"), "That was amazing 😂", "voice emoji")
        eq(TextCleanup.clean("love you heart emoji thumbs up emoji", language: "en"), "Love you ❤️ 👍", "two emoji")
        let (sent, flag) = TextCleanup.stripSend("I'm coming in 5 minutes send")
        c.check(flag && sent == "I'm coming in 5 minutes", "'… send' strips the word and sends", "got: \(sent) \(flag)")
        c.check(!TextCleanup.stripSend("please resend it").1, "'resend' is not a send command")
        c.check(!TextCleanup.stripSend("send").1, "'send' alone is not stripped")

        eq(NumberWords.digitize("it was nine GB and mine is one point five MB"), "it was 9 GB and mine is 1.5 MB", "sizes as digits")
        eq(NumberWords.digitize("meet at five, I need twenty five minutes"), "meet at 5, I need 25 minutes", "times and minutes")
        eq(NumberWords.digitize("this one is better and no one came"), "this one is better and no one came", "'one' as a word stays")
        eq(NumberWords.digitize("three lakh rupees and two point five crore"), "3 lakh rupees and 2.5 crore", "lakh / crore")
        eq(NumberWords.digitize("call nine eight seven six five four three two one zero"), "call 9876543210", "phone number")
        eq(NumberWords.digitize("grew by twelve percent"), "grew by 12%", "percent")

        eq(StyleEngine.apply(.casual, to: "Hey, are you free? Let's do 12 if that works for you."), "Hey are you free? Let's do 12 if that works for you", "casual style")
        eq(StyleEngine.apply(.veryCasual, to: "Hey, are you free? Let's do 12."), "hey are you free? let's do 12", "very casual style")
        eq(StyleEngine.apply(.formal, to: "Thanks for the update"), "Thanks for the update.", "formal adds the full stop")

        eq(Pipeline.normalizeHinglish("kya tum aaj Shaam ko free ho"), "tum aaj shaam ko free ho?", "yes/no 'kya' question normalised")
        eq(Pipeline.normalizeHinglish("kya kar rahe ho"), "kya kar rahe ho?", "'kya' meaning 'what' is kept")
        eq(NumberWords.digitize("mine is one. 5 MB and 2. 5 GB"), "mine is 1.5 MB and 2.5 GB", "recognizer's broken decimals fixed")
        eq(TextCleanup.clean("UHH mujhe lagta hai UNN hum kal chalenge", language: "hi"), "Mujhe lagta hai hum kal chalenge", "Hindi filler sounds removed")
        c.check(LanguageCatalog.detect("mujhe lagta hai ki hamen kal milna chahiye") == "hi", "detects Hinglish in Roman letters")
        c.check(LanguageCatalog.detect("Can you send me the report?") == "en", "detects English")
        c.check(LanguageCatalog.detect("मैं कल ऑफिस आऊंगा") == "hi", "detects Devanagari Hindi")

        if let (a, b) = CorrectionLearner.change(from: "I love Wisper flow", to: "I love Wispr flow", within: "I love Wisper flow") {
            c.check(a == "Wisper" && b == "Wispr", "learns a spelling fix", "got \(a)->\(b)")
        } else { c.check(false, "learns a spelling fix") }
        c.check(CorrectionLearner.change(from: "Hi there", to: "Hi there and more typing", within: "Hi there") == nil, "typing more is not a correction")
        return c.finish("Text tests")
    }
}

// MARK: - Audio corpus (spoken by macOS voices, run through the live pipeline)

@MainActor
enum AudioTests {
    struct Case {
        let name: String
        let voice: String
        let text: String
        let locale: String
        let mode: DictationMode
        var contains: [String] = []
        var notContains: [String] = []
        var english = false
        var roman = false
        var aiOnly = false
        var sayToSend = false
    }

    static let cases: [Case] = [
        Case(name: "English fillers", voice: "Rishi", text: "Um, so I was, uh, thinking we could ship the new design on Friday.", locale: "en-IN", mode: .asSpoken,
             contains: ["Friday"], notContains: ["Um", "um,", "uh", "Uh"]),
        Case(name: "English sizes as digits", voice: "Rishi", text: "The old app was nine GB and mine is one point five MB.", locale: "en-IN", mode: .asSpoken,
             contains: ["9 GB", "1.5 MB"]),
        Case(name: "English new line", voice: "Rishi", text: "Hi Rahul. New line. Please call me back.", locale: "en-IN", mode: .asSpoken,
             contains: ["\n\n"], notContains: ["new line", "New line"]),
        Case(name: "English emoji", voice: "Rishi", text: "That was so funny, laughing emoji.", locale: "en-IN", mode: .asSpoken,
             contains: ["😂"]),
        Case(name: "Say send to send", voice: "Rishi", text: "I am coming in five minutes. Send.", locale: "en-IN", mode: .asSpoken,
             notContains: ["Send", "send"], sayToSend: true),
        Case(name: "English self-correction", voice: "Rishi", text: "Let's meet at two, no wait, at three.", locale: "en-IN", mode: .asSpoken,
             contains: ["3"], notContains: ["two", "2", "no wait"], aiOnly: true),
        Case(name: "English spoken, Hindi set as language", voice: "Rishi", text: "When I hold the option key it translates, but with option and shift it should not translate.",
             locale: "hi-IN", mode: .asSpoken, contains: ["option key", "shift", "translate"], notContains: ["medicine"], english: true),
        Case(name: "English spoken into translate key", voice: "Rishi", text: "Um, can you send me the invoice by tonight?",
             locale: "hi-IN", mode: .translate, contains: ["invoice", "tonight"], notContains: ["Um"], english: true),
        Case(name: "Hindi as spoken stays Hinglish", voice: "Lekha", text: "मुझे लगता है कि हमें कल की मीटिंग शुक्रवार को शिफ्ट कर देनी चाहिए।", locale: "hi-IN", mode: .asSpoken,
             contains: ["meeting"], roman: true),
        Case(name: "Hindi filler sounds removed", voice: "Lekha", text: "uhh मुझे लगता है, umm, हम कल चलेंगे", locale: "hi-IN", mode: .asSpoken,
             contains: ["lagta"], notContains: ["UHH", "UNN", "uhh", "umm", "Umm"], roman: true),
        Case(name: "Hindi → English", voice: "Lekha", text: "मुझे लगता है कि हमें कल की मीटिंग शुक्रवार को शिफ्ट कर देनी चाहिए।", locale: "hi-IN", mode: .translate,
             contains: ["meeting", "Friday"], english: true),
        Case(name: "Hindi → English, sick day", voice: "Lekha", text: "भाई कल ऑफिस नहीं आ पाऊंगा, तबियत थोड़ी खराब है।", locale: "hi-IN", mode: .translate,
             contains: ["office", "tomorrow"], english: true),
        Case(name: "Hindi → English question", voice: "Lekha", text: "क्या तुम आज रात को फ्री हो?", locale: "hi-IN", mode: .translate,
             contains: ["tonight", "?"], notContains: ["Why"], english: true),
        Case(name: "Hindi → English request", voice: "Lekha", text: "क्या आप रिपोर्ट आज शाम तक भेज सकते हैं?", locale: "hi-IN", mode: .translate,
             contains: ["report", "evening", "?"], english: true),
        Case(name: "Hindi → English numbers", voice: "Lekha", text: "उसका ऐप नौ जीबी का था।", locale: "hi-IN", mode: .translate,
             contains: ["9 GB"], english: true),
    ]

    static func run(includeAI: Bool, onlyAI: Bool) async -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lipi-audio-tests")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = Settings.shared
        let savedSend = settings.sayToSend, savedAI = settings.aiEnabled
        defer { settings.sayToSend = savedSend; settings.aiEnabled = savedAI }

        var c = Checker()
        var times: [Int] = []
        let speech = SpeechEngine()
        let pipeline = Pipeline()
        for useAI in onlyAI ? [true] : (includeAI ? [false, true] : [false]) {
            settings.aiEnabled = useAI
            print("\n— \(useAI ? "AI mode (Gemini)" : "On-device") —")
            for (index, test) in cases.enumerated() where !test.aiOnly || useAI {
                // Stable name per sentence, so editing a case regenerates its audio.
                let hash = test.text.unicodeScalars.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
                let file = dir.appendingPathComponent("case-\(index)-\(String(hash, radix: 36)).aiff")
                if !FileManager.default.fileExists(atPath: file.path) {
                    let say = Process()
                    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    say.arguments = ["-v", test.voice, "-o", file.path, test.text]
                    try? say.run(); say.waitUntilExit()
                }
                settings.sayToSend = test.sayToSend
                guard let r = await TestRunner.transcribe(path: file.path, locale: test.locale, mode: test.mode, realtime: true,
                                                          speech: speech, pipeline: pipeline) else {
                    c.check(false, test.name, "no result"); continue
                }
                times.append(r.ms)
                var problems: [String] = []
                for s in test.contains where !r.output.localizedCaseInsensitiveContains(s) && !(s == "\n\n" && r.output.contains("\n\n")) { problems.append("missing \(s.debugDescription)") }
                for s in test.notContains where r.output.contains(s) { problems.append("has \(s.debugDescription)") }
                if test.english && LanguageCatalog.detect(r.output) != "en" { problems.append("not English") }
                if test.roman && !LanguageCatalog.isLatin(r.output) { problems.append("not in Roman letters") }
                if test.sayToSend && !r.send { problems.append("didn't send") }
                if useAI && !r.usedAI { problems.append("AI not used") }
                c.check(problems.isEmpty, "\(test.name) [\(r.ms) ms]: \(r.output.replacingOccurrences(of: "\n", with: "⏎"))",
                        problems.joined(separator: ", ") + "  (heard: \(r.raw))")
            }
        }
        if !times.isEmpty {
            let sorted = times.sorted()
            print("release→text: median \(sorted[sorted.count / 2]) ms, worst \(sorted.last!) ms")
        }
        return c.finish("Audio tests")
    }
}

// MARK: - End to end: the real app, a real text box

@MainActor
enum EndToEnd {
    /// Needs the app running with `defaults write app.lipi.mac testHooks -bool YES` and a text box
    /// focused (the harness script opens TextEdit). Sends each clip to the app, which records it
    /// through the normal path, pastes into the focused app and reports what landed.
    static func run(keys: Bool) async -> Int32 {
        var c = Checker()
        let report = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lipi-test.json")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lipi-audio-tests")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clips: [(String, String, String, String, [String])] = [
            ("dictate", "Rishi", "Um, the old app was nine GB and mine is one point five MB.", "as spoken", ["9 GB", "1.5 MB"]),
            ("translate", "Lekha", "भाई कल ऑफिस नहीं आ पाऊंगा, तबियत थोड़ी खराब है।", "translate (hands-free)", ["office"]),
            ("dictate", "Lekha", "क्या तुम आज रात को फ्री हो?", "as spoken Hinglish", ["free"]),
        ]
        // 1. The microphone opens only while dictating, uses the built-in mic, and is released after.
        try? FileManager.default.removeItem(at: report)
        DistributedNotificationCenter.default().postNotificationName(.init("app.lipi.test"), object: nil, userInfo: ["action": "micCheck"], deliverImmediately: true)
        var mic: [String: Any]?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if let data = try? Data(contentsOf: report), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { mic = json; break }
        }
        if let m = mic {
            c.check(m["openBefore"] as? Bool == false, "mic is closed while idle (headphones keep playing normally)")
            c.check(m["openDuring"] as? Bool == true && (m["buffers"] as? Int ?? 0) > 5, "mic opens while dictating [\(m["startMs"] ?? "?") ms to start, \(m["builtIn"] ?? "")]", "\(m)")
            c.check(m["openAfter"] as? Bool == false, "mic is fully released right after", "\(m)")
            let before = m["outBefore"] as? Double ?? 0, during = m["outDuring"] as? Double ?? 0, after = m["outAfter"] as? Double ?? 0
            c.check(before == during && during == after, "headphones keep music quality while dictating [\(Int(before)) → \(Int(during)) → \(Int(after)) Hz]")
        } else { c.check(false, "mic check: app reported nothing") }

        for (i, clip) in clips.enumerated() {
            let file = dir.appendingPathComponent("e2e-\(i).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", clip.1, "-o", file.path, clip.2]
            try? say.run(); say.waitUntilExit()
            try? FileManager.default.removeItem(at: report)
            var info: [String: Any] = ["action": clip.0, "file": file.path]
            if i == 1 { info["handsFree"] = true }
            if keys { info["keys"] = true }
            DistributedNotificationCenter.default().postNotificationName(.init("app.lipi.test"), object: nil, userInfo: info, deliverImmediately: true)
            var result: [String: Any]?
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(250))
                if let data = try? Data(contentsOf: report), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result = json; break }
            }
            guard let r = result else { c.check(false, "\(clip.3): app reported nothing (is it running with test hooks?)"); continue }
            let output = r["output"] as? String ?? ""
            let field = r["field"] as? String ?? ""
            let pasted = r["pasted"] as? Bool ?? false
            var problems: [String] = []
            if !pasted { problems.append("not pasted (Accessibility off?)") }
            if output.isEmpty || !field.contains(output) { problems.append("text box doesn't contain the output (field: \(field.suffix(80)))") }
            for s in clip.4 where !output.localizedCaseInsensitiveContains(s) { problems.append("missing \(s)") }
            c.check(problems.isEmpty, "\(clip.3) [\(r["ms"] ?? 0) ms, AI \(r["usedAI"] ?? false)] → \(output)", problems.joined(separator: ", "))
            try? await Task.sleep(for: .milliseconds(600))
        }
        return c.finish("End-to-end tests")
    }
}
