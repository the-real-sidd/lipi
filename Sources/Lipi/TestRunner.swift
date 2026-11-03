import AVFoundation
import FoundationModels
import Speech

/// Command-line tools for testing Lipi without clicking around.
///
///   Lipi --status [--locale hi-IN]          what's installed
///   Lipi --install hi-IN                    download a speech model (managed by macOS)
///   Lipi --transcribe FILE [--locale hi-IN] [--to en|same] [--style formal|casual|veryCasual] [--realtime]
///   Lipi --translate TEXT [--from auto|hi] [--to en]
///   Lipi --clean TEXT [--lang en]
///   Lipi --style TEXT --as casual
///   Lipi --summarize FILE.txt               summarise a "Me: … / Others: …" transcript
///   Lipi --mic-users                        apps using the microphone right now
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
            return 0

        case "--install":
            let l = value("--install") ?? "hi-IN"
            let clock = Clock()
            var shown = -1
            do {
                try await SpeechEngine.install(l) { f in
                    let pct = Int(f * 100)
                    if pct / 10 != shown / 10 { shown = pct; print("  \(pct)%") }
                }
                print("installed \(l) in \(clock.ms) ms -> \(await SpeechEngine.status(l))")
                return 0
            } catch {
                print("install failed: \(error)")
                return 1
            }

        case "--clean":
            print(TextCleanup.clean(value("--clean") ?? "", language: value("--lang") ?? "en"))
            return 0

        case "--style":
            let style = WritingStyle(rawValue: value("--as") ?? "casual") ?? .casual
            print(StyleEngine.apply(style, to: value("--style") ?? ""))
            return 0

        case "--diff":
            // --diff BEFORE AFTER INSERTED
            let a = args.count > 3 ? Array(args[1...3]) : ["", "", ""]
            if let (old, new) = CorrectionLearner.change(from: a[0], to: a[1], within: a[2]) {
                print("change: \(old) -> \(new), similarity \(String(format: "%.2f", CorrectionLearner.similarity(old.lowercased(), new.lowercased())))")
            } else { print("no learnable change") }
            return 0

        case "--numbers":
            print(NumberWords.digitize(value("--numbers") ?? ""))
            return 0

        case "--detect":
            print(LanguageCatalog.detect(value("--detect") ?? "") ?? "unknown")
            return 0

        case "--mic-users":
            for p in AudioDevices.processesUsingMicrophone() {
                print("\(p.pid) \(p.bundle) -> \(MeetingDetector.meetingApp(for: p.bundle)?.name ?? "not a meeting app")")
            }
            return 0

        case "--translate":
            let text = value("--translate") ?? ""
            let fromArg = value("--from") ?? "auto"
            let from = fromArg == "auto" ? (LanguageCatalog.detect(text) ?? "hi") : fromArg
            let to = value("--to") ?? "en"
            let translator = Translator()
            do {
                let cold = Clock()
                let out = try await translator.translate(text, from: from, to: to)
                let coldMs = cold.ms
                let warm = Clock()
                _ = try await translator.translate(text, from: from, to: to)
                print("\(from)->\(to): \(out)")
                print("cold \(coldMs) ms, warm \(warm.ms) ms")
                return 0
            } catch {
                print("translate failed: \(error)")
                return 1
            }

        case "--bench-translate":
            let translator = Translator()
            let sentences = args.dropFirst()
            await translator.warmUp(from: "hi", to: "en")
            for s in sentences {
                let c = Clock()
                let out = (try? await translator.translate(Pipeline.normalizeHinglish(s), from: "hi", to: "en")) ?? "<failed>"
                print("\(c.ms) ms  \(s)  ->  \(out)")
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

        case "--transcribe":
            guard let path = value("--transcribe") else { print("missing file"); return 1 }
            let to = value("--to") ?? "en"
            let style = WritingStyle(rawValue: value("--style") ?? "formal") ?? .formal
            Settings.shared.setStyle(style, for: .other)
            return await transcribe(path: path, locale: locale, target: to == "same" ? nil : to, realtime: args.contains("--realtime"))

        default:
            print("""
            Lipi --status | --install hi-IN | --mic-users
            Lipi --transcribe FILE [--locale hi-IN] [--to en|same] [--style formal|casual|veryCasual] [--realtime]
            Lipi --translate TEXT [--from auto] [--to en]
            Lipi --clean TEXT [--lang en] | --style TEXT --as casual | --detect TEXT | --summarize FILE
            """)
            return 0
        }
    }

    /// Plays a file through the exact live pipeline. With --realtime the audio is fed at
    /// speaking speed, so "release → text" is the same number you'd feel in the app.
    private static func transcribe(path: String, locale: String, target: String?, realtime: Bool) async -> Int32 {
        let speech = SpeechEngine()
        let pipeline = Pipeline()
        let warm = Clock()
        guard let format = await speech.format(for: locale) else { print("speech model for \(locale) not installed"); return 1 }
        await speech.prepareStandby(locale)
        if let target { await pipeline.translator.warmUp(from: LanguageCatalog.languageCode(ofLocale: locale), to: target) }
        print("warm-up: \(warm.ms) ms")

        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { print("can't open \(path)"); return 1 }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let converter = StreamConverter(output: format)

        var partials = 0
        let session: SpeechEngine.Session
        do {
            session = try await speech.begin(locale, input: stream, onPartial: { text in
                partials += 1
                pipeline.prefetch(text, speechLocale: locale, target: target)
            })
        } catch {
            print("begin failed: \(error)")
            return 1
        }

        let chunk: AVAudioFrameCount = 2048
        let chunkSeconds = Double(chunk) / file.processingFormat.sampleRate
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
            if realtime { try? await Task.sleep(for: .seconds(chunkSeconds)) }
        }
        let released = Clock()
        continuation.finish()
        let raw = await speech.finish(session)
        let speechMs = released.ms
        let output = await pipeline.produce(raw, speechLocale: locale, target: target, category: .other)
        let total = released.ms

        print("audio: \(String(format: "%.1f", duration)) s, live updates: \(partials)")
        print("heard: \(raw)")
        switch output {
        case .text(let text, let note):
            print("typed: \(text)")
            if let note { print("note: \(note)") }
        case .undo: print("typed: <undo>")
        case .empty: print("typed: <nothing>")
        }
        print("release→text: \(total) ms (speech tail \(speechMs) ms, translate \(pipeline.lastTiming.translateMs) ms, polish \(pipeline.lastTiming.polishMs) ms)")
        return 0
    }
}
