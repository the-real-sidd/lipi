import Foundation

/// Turns a raw transcript into the text that gets typed.
///   1. voice commands ("new line", "heart emoji", "… send")
///   2. AI mode (Gemini, if you added a key): cleanup or translation in one step
///      otherwise on-device: rule cleanup → Apple Translation → Apple Intelligence for corrections
///   3. digits for numbers, learned fixes, writing style for the app you're in, your dictionary
@MainActor
final class Pipeline {
    enum Output: Equatable {
        case text(String, note: String?, send: Bool)
        case undo
        case empty
    }

    struct Timing { var translateMs = 0; var polishMs = 0; var aiMs = 0; var usedAI = false }

    let translator = Translator()
    let polisher = Polisher()
    let dictionary = PersonalDictionary()
    let memory = TranslationMemory.shared
    private(set) var lastTiming = Timing()

    func produce(_ raw: String, speechLocale: String, mode: DictationMode, category: AppCategory) async -> Output {
        lastTiming = Timing()
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if TextCleanup.command(in: trimmed) == .undo { return .undo }

        var send = false
        if Settings.shared.sayToSend { (trimmed, send) = TextCleanup.stripSend(trimmed) }

        let spoken = LanguageCatalog.languageCode(ofLocale: speechLocale)
        let target: String? = mode == .translate ? Settings.shared.outputLanguage.nonEmpty ?? "en" : nil
        let commanded = Settings.shared.voiceCommands ? TextCleanup.applyCommands(trimmed) : trimmed

        var text = ""
        var note: String?
        var outputLanguage = target ?? spoken

        // AI mode: one request does cleanup (and translation) the way Wispr Flow does.
        if AIService.shared.isEnabled {
            let clock = Clock()
            do {
                if let target {
                    let from = LanguageCatalog.detect(commanded) ?? spoken
                    text = try await AIWriter.translate(commanded, from: from, to: target, words: dictionary.words)
                } else {
                    text = try await AIWriter.clean(commanded, language: spoken, words: dictionary.words)
                }
                lastTiming.usedAI = true
            } catch {
                Log.write("AI fallback: \(error.localizedDescription)")
                text = ""
            }
            lastTiming.aiMs = clock.ms
        }

        if text.isEmpty {
            text = TextCleanup.clean(trimmed, language: spoken)
            if text.isEmpty { return .empty }
            if let target {
                let detected = LanguageCatalog.detect(text) ?? spoken
                if detected != target {
                    let clock = Clock()
                    do {
                        let input = detected == "hi" && LanguageCatalog.isLatin(text) ? Self.normalizeHinglish(text) : text
                        text = try await translator.translate(input, from: detected, to: target)
                        text = TextCleanup.tidy(text, english: LanguageCatalog.isLatin(text))
                    } catch {
                        Log.write("translate failed: \(error.localizedDescription)")
                        note = "Translation to \(LanguageCatalog.name(target)) isn't downloaded yet, so this is as spoken."
                        outputLanguage = spoken
                    }
                    lastTiming.translateMs = clock.ms
                }
            }
            if outputLanguage == "en" && Settings.shared.smartCleanup && TextCleanup.needsSmartCleanup(text) {
                let clock = Clock()
                if let better = await polisher.polish(text) { text = better }
                lastTiming.polishMs = clock.ms
            }
        }

        if outputLanguage == "en" || (LanguageCatalog.isLatin(text) && LanguageCatalog.detect(text) == "en") {
            text = NumberWords.digitize(text)
        }
        text = memory.apply(to: text, source: trimmed)
        text = StyleEngine.apply(Settings.shared.style(for: category), to: text)
        text = dictionary.apply(text)
        return .text(text, note: note, send: send)
    }

    /// Apple's Hindi recognizer writes Hinglish in Roman letters and capitalises Hindi words at
    /// random ("aaj Shaam tak Bhej"), which the translator mistakes for names. Lowercasing fixes
    /// it ("…by this evening"). Acronyms stay, and dictionary names get their casing back later.
    static func normalizeHinglish(_ text: String) -> String {
        let lowered = text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let letters = word.filter(\.isLetter)
            if letters.count >= 2 && letters.allSatisfy(\.isUppercase) { return String(word) } // PDF, OK
            return word.lowercased()
        }
        .joined(separator: " ")
        // A leading "kya" that just marks a yes/no question ("kya tum free ho") reads as "why" to the
        // translator. Drop it and keep the question mark: "tum free ho?" -> "Are you free?".
        let subjects: Set<String> = ["tum", "aap", "tu", "main", "mai", "mei", "hum", "wo", "woh", "ye", "yeh", "aapne", "tumne", "usne",
                                     "unhone", "aapko", "tumhe", "tumko", "use", "unko", "isko", "usko", "sab", "koi"]
        return lowered.components(separatedBy: "\n").map { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            let words = l.split(separator: " ").map(String.init)
            if words.first == "kya", words.count > 2, subjects.contains(words[1].trimmingCharacters(in: .punctuationCharacters)) {
                l = words.dropFirst().joined(separator: " ")
                if let last = l.last, !"?!.".contains(last) { l += "?" }
            } else if words.first == "kya", !l.hasPrefix("kya baat"), let last = l.last, !"?!.".contains(last) {
                l += "?"
            }
            return l
        }
        .joined(separator: "\n")
    }

    private var prefetching = false
    private var lastPrefetch = Date.distantPast

    /// Called with the live transcript while you speak. Keeps the on-device translation model
    /// loaded (macOS unloads it after a few idle seconds) and the AI connection open, so the
    /// work after you let go starts warm.
    func prefetch(_ partial: String, speechLocale: String, mode: DictationMode) {
        if AIService.shared.isEnabled { AIService.shared.warmUp(); return }
        guard mode == .translate, !prefetching, Date().timeIntervalSince(lastPrefetch) > 1.5,
              partial.split(separator: " ").count >= 3 else { return }
        let target = Settings.shared.outputLanguage.nonEmpty ?? "en"
        let spoken = LanguageCatalog.languageCode(ofLocale: speechLocale)
        guard spoken != target else { return }
        prefetching = true
        lastPrefetch = Date()
        let input = spoken == "hi" && LanguageCatalog.isLatin(partial) ? Self.normalizeHinglish(partial) : partial
        Task {
            _ = try? await translator.translate(input, from: spoken, to: target)
            prefetching = false
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
