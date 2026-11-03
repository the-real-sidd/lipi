import AVFoundation
import Speech

/// On-device streaming speech recognition using Apple's SpeechAnalyzer.
///
/// Speed tricks:
/// * Models stay loaded for the life of the app (`modelRetention: .processLifetime`).
/// * A "standby" analyzer is fully prepared ahead of time, so pressing the hotkey only has to
///   start feeding audio. A new standby is prepared right after each dictation.
/// * Audio is transcribed while you speak, so letting go only waits for the last word or two.
@MainActor
final class SpeechEngine {
    @MainActor
    final class Session {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let locale: String
        var finalized = ""
        var volatile = ""
        var resultsTask: Task<Void, Never>?
        var onPartial: ((String) -> Void)?
        var onFinal: ((String, Double) -> Void)?

        /// Hindi speakers switch to English mid-day. A second, English recognizer hears the same
        /// audio; whichever matches what was actually spoken wins.
        let english: SpeechTranscriber?
        var englishFinal = ""
        var englishVolatile = ""
        var englishTask: Task<Void, Never>?
        private(set) var pickedEnglish = false

        init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, english: SpeechTranscriber?, locale: String) {
            self.analyzer = analyzer
            self.transcriber = transcriber
            self.english = english
            self.locale = locale
        }

        var text: String { SpeechEngine.join(finalized, volatile) }
        var englishText: String { SpeechEngine.join(englishFinal, englishVolatile) }

        /// The transcript to use: English when the speaker was clearly talking English.
        func best() -> String {
            let primary = text, other = englishText
            guard english != nil, !other.isEmpty else { return primary }
            if primary.isEmpty { pickedEnglish = true; return other }
            if LanguageCatalog.isLatin(primary), LanguageCatalog.detect(primary) == "en" {
                pickedEnglish = true
                return other
            }
            return primary
        }
    }

    private var formats: [String: AVAudioFormat] = [:]
    private var standby: Session?
    var contextualWords: [String] = []

    nonisolated static func makeTranscriber(_ locale: String) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: locale),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    // MARK: Model assets (downloaded and managed by macOS, not shipped in the app)

    nonisolated static func status(_ locale: String) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [makeTranscriber(locale)])
    }

    nonisolated static func install(_ locale: String, progress: @escaping (Double) -> Void) async throws {
        let transcriber = makeTranscriber(locale)
        _ = try? await AssetInventory.reserve(locale: Locale(identifier: locale))
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        progress(1)
    }

    // MARK: Sessions

    /// The English companion recognizer used for `locale`, if any.
    private static func companion(for locale: String) -> String? {
        let lang = LanguageCatalog.languageCode(ofLocale: locale)
        let indic: Set<String> = ["hi", "mr", "bn", "gu", "pa", "ta", "te", "kn", "ml", "ur", "or", "ne"]
        return indic.contains(lang) ? "en-IN" : nil
    }

    private var companionReady: [String: Bool] = [:]
    private func usesCompanion(_ locale: String) async -> String? {
        guard Settings.shared.mixedEnglish, let other = Self.companion(for: locale) else { return nil }
        if let ready = companionReady[other] { return ready ? other : nil }
        let ready = await Self.status(other) == .installed
        companionReady[other] = ready
        return ready ? other : nil
    }

    func format(for locale: String) async -> AVAudioFormat? {
        if let f = formats[locale] { return f }
        guard await Self.status(locale) == .installed else { return nil }
        var modules: [any SpeechModule] = [Self.makeTranscriber(locale)]
        if let other = await usesCompanion(locale) { modules.append(Self.makeTranscriber(other)) }
        let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        formats[locale] = f
        return f
    }

    func cachedFormat(for locale: String) -> AVAudioFormat? { formats[locale] }

    private func makeSession(_ locale: String, mixed: Bool = true) async throws -> Session {
        guard let format = await format(for: locale) else {
            throw NSError(domain: "Lipi", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech model not installed"])
        }
        let transcriber = Self.makeTranscriber(locale)
        let companion = mixed ? await usesCompanion(locale) : nil
        let english = companion.map { Self.makeTranscriber($0) }
        let analyzer = SpeechAnalyzer(
            modules: [transcriber] + (english.map { [$0] } ?? []),
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        if !contextualWords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualWords
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        return Session(analyzer: analyzer, transcriber: transcriber, english: english, locale: locale)
    }

    /// Loads the model and builds a ready-to-go analyzer. Safe to call repeatedly.
    func prepareStandby(_ locale: String) async {
        if let standby, standby.locale == locale { return }
        let clock = Clock()
        do {
            standby = try await makeSession(locale)
            Log.write("speech standby ready (\(locale)) in \(clock.ms) ms")
        } catch {
            Log.write("speech prepare skipped (\(locale)): \(error.localizedDescription)")
        }
    }

    func resetStandby() { standby = nil }

    /// Starts transcribing `input`. Returns as soon as the analyzer is running.
    /// `useStandby: false` gives an independent session (meetings run two at once).
    func begin(_ locale: String, input: AsyncStream<AnalyzerInput>, useStandby: Bool = true,
               onPartial: ((String) -> Void)? = nil, onFinal: ((String, Double) -> Void)? = nil) async throws -> Session {
        let session: Session
        if useStandby, let ready = standby, ready.locale == locale {
            session = ready
            standby = nil
        } else {
            // Meetings (useStandby: false) keep one recognizer so segments aren't doubled.
            session = try await makeSession(locale, mixed: useStandby)
        }
        session.onPartial = onPartial
        session.onFinal = onFinal
        let transcriber = session.transcriber
        session.resultsTask = Task { [session] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        session.finalized = Self.join(session.finalized, text)
                        session.volatile = ""
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { session.onFinal?(trimmed, result.range.start.seconds) }
                    } else {
                        session.volatile = text
                    }
                    session.onPartial?(session.text)
                }
            } catch {
                Log.write("results error: \(error.localizedDescription)")
            }
        }
        if let english = session.english {
            session.englishTask = Task { [session] in
                do {
                    for try await result in english.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            session.englishFinal = Self.join(session.englishFinal, text)
                            session.englishVolatile = ""
                        } else {
                            session.englishVolatile = text
                        }
                    }
                } catch {
                    Log.write("english results error: \(error.localizedDescription)")
                }
            }
        }
        try await session.analyzer.start(inputSequence: input)
        return session
    }

    /// Call after the audio stream has finished. Waits only for the tail of the speech.
    func finish(_ session: Session) async -> String {
        do {
            try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.write("finalize error: \(error.localizedDescription)")
        }
        await session.resultsTask?.value
        await session.englishTask?.value
        return session.best()
    }

    func cancel(_ session: Session) async {
        await session.analyzer.cancelAndFinishNow()
        session.resultsTask?.cancel()
        session.englishTask?.cancel()
    }

    nonisolated static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces)
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
