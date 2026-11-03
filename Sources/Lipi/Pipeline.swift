import Foundation

/// Turns a raw transcript into the text that gets typed.
///   1. spoken commands and rule-based cleanup (instant)
///   2. translation into your "type in" language, on-device (skipped when you hold Shift)
///   3. Apple Intelligence rewrite, only when you corrected yourself mid-sentence
///   4. writing style for the app you're in (formal / casual / very casual)
///   5. your personal dictionary
@MainActor
final class Pipeline {
    enum Output: Equatable {
        case text(String, note: String?)
        case undo
        case empty
    }

    struct Timing { var translateMs = 0; var polishMs = 0 }

    let translator = Translator()
    let polisher = Polisher()
    let dictionary = PersonalDictionary()
    let memory = TranslationMemory.shared
    private(set) var lastTiming = Timing()

    /// - Parameters:
    ///   - target: language code to type in, or nil to keep the language you spoke.
    func produce(_ raw: String, speechLocale: String, target: String?, category: AppCategory) async -> Output {
        lastTiming = Timing()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if TextCleanup.command(in: trimmed) == .undo { return .undo }

        let spoken = LanguageCatalog.languageCode(ofLocale: speechLocale)
        var text = TextCleanup.clean(trimmed, language: spoken)
        if text.isEmpty { return .empty }

        var note: String?
        var outputLanguage = spoken
        if let target, target != spoken {
            let detected = LanguageCatalog.detect(text) ?? spoken
            outputLanguage = target
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

        if outputLanguage == "en" { text = NumberWords.digitize(text) }
        text = memory.apply(to: text, source: trimmed)
        text = StyleEngine.apply(Settings.shared.style(for: category), to: text)
        text = dictionary.apply(text)
        return .text(text, note: note)
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
        // "kya ..." without a question mark reads as "why ..." to the translator.
        return lowered.components(separatedBy: "\n").map { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("kya "), !l.hasPrefix("kya baat"), let last = l.last, !"?!.".contains(last) { l += "?" }
            return l
        }
        .joined(separator: "\n")
    }

    private var prefetching = false
    private var lastPrefetch = Date.distantPast

    /// Called with the live transcript while you speak. Translating it in the background keeps
    /// the translation model loaded (macOS unloads it after a few idle seconds), so the real
    /// translation after you let go takes ~70 ms instead of ~400 ms.
    func prefetch(_ partial: String, speechLocale: String, target: String?) {
        guard let target, !prefetching, Date().timeIntervalSince(lastPrefetch) > 1.5,
              partial.split(separator: " ").count >= 3 else { return }
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
