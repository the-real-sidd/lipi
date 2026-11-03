import Foundation
import NaturalLanguage
import Speech
import Translation

struct LanguageChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Languages this Mac can recognise (speech) and translate, straight from the OS.
@MainActor
final class LanguageCatalog: ObservableObject {
    static let shared = LanguageCatalog()
    @Published private(set) var speechLocales: [LanguageChoice] = []
    @Published private(set) var translationLanguages: [LanguageChoice] = []

    func load() async {
        guard speechLocales.isEmpty else { return }
        let locales = await SpeechTranscriber.supportedLocales
        speechLocales = locales
            .map { $0.identifier(.bcp47) }
            .filter { !$0.hasPrefix("mul") }
            .map { LanguageChoice(id: $0, name: Self.name($0)) }
            .sorted { $0.name < $1.name }
        var seen = Set<String>()
        let languages = await LanguageAvailability().supportedLanguages
        translationLanguages = languages
            .compactMap { lang -> LanguageChoice? in
                let id = lang.minimalIdentifier
                guard seen.insert(id).inserted else { return nil }
                return LanguageChoice(id: id, name: Self.name(id))
            }
            .sorted { $0.name < $1.name }
    }

    nonisolated static func name(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// "hi-IN" -> "hi"
    nonisolated static func languageCode(ofLocale id: String) -> String {
        Locale(identifier: id).language.languageCode?.identifier ?? id
    }

    /// Hinglish words that give away Hindi written in Roman letters.
    nonisolated private static let hinglish: Set<String> = [
        "hai", "hain", "kya", "nahi", "nahin", "mujhe", "mera", "meri", "tum", "tumhe", "aap", "aapka", "hum", "humein",
        "kar", "karo", "karna", "raha", "rahi", "rahe", "tha", "thi", "the", "ho", "hoga", "ka", "ki", "ko", "se", "mein",
        "yaar", "bhai", "kal", "aaj", "abhi", "kaise", "kyun", "kab", "kahan", "acha", "accha", "theek", "chalo", "matlab",
        "bhej", "dena", "lena", "sakte", "sakta", "chahiye", "lagta", "bahut", "bhi", "toh", "aur",
    ]

    /// Best guess at the language of `text`, as a translation language code.
    nonisolated static func detect(_ text: String) -> String? {
        var counts: [String: Int] = [:]
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0900...0x097F: counts["hi", default: 0] += 1
            case 0x0980...0x09FF: counts["bn", default: 0] += 1
            case 0x0B80...0x0BFF: counts["ta", default: 0] += 1
            case 0x0C00...0x0C7F: counts["te", default: 0] += 1
            case 0x0600...0x06FF: counts["ur", default: 0] += 1
            default: break
            }
        }
        if let (script, n) = counts.max(by: { $0.value < $1.value }), n >= 3 {
            if script == "ur" { return NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "ar" }
            return script
        }
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        if !words.isEmpty {
            let hits = words.filter { hinglish.contains($0) }.count
            if hits >= 2 && Double(hits) / Double(words.count) >= 0.15 { return "hi" }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value > 0.5 else { return nil }
        let code = best.key.rawValue
        return code.hasPrefix("zh") ? "zh" : code
    }

    nonisolated static func isLatin(_ text: String) -> Bool {
        var latin = 0, other = 0
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            if s.value < 0x0250 { latin += 1 } else { other += 1 }
        }
        return latin >= other
    }
}
