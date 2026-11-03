import Foundation

/// Fast, rule-based cleanup. Runs in well under a millisecond, so most dictations never
/// need a language model at all.
enum TextCleanup {
    enum Command { case undo }

    // MARK: Spoken commands

    private static let undoPattern = rx(#"^\s*(?:scratch that|delete that|undo that|इसे हटा दो|इसको हटा दो|हटा दो|इसे हटाओ|स्क्रैच दैट)\s*[.!।]?\s*$"#)
    private static let newParagraph = rx(#"\s*[,.]?\s*(?:new paragraph|naya paragraph|नया पैराग्राफ|न्यू पैराग्राफ)\s*[,.।]?\s*"#)
    private static let newLine = rx(#"\s*[,.]?\s*(?:new line|nayi line|नई लाइन|नयी लाइन|न्यू लाइन)\s*[,.।]?\s*"#)

    static func command(in text: String) -> Command? {
        matches(undoPattern, text) ? .undo : nil
    }

    private static let emoji: [(String, String)] = [
        ("heart", "❤️"), ("red heart", "❤️"), ("laughing", "😂"), ("laughing crying", "😂"), ("logging", "😂"), ("lafing", "😂"), ("laughter", "😂"), ("rolling laughing", "🤣"),
        ("thumbs up", "👍"), ("thumbs down", "👎"), ("smiley", "😊"), ("smile", "😊"), ("smiling", "😊"), ("wink", "😉"),
        ("fire", "🔥"), ("folded hands", "🙏"), ("namaste", "🙏"), ("pray", "🙏"), ("crying", "😢"), ("sad", "😢"),
        ("party", "🎉"), ("celebration", "🎉"), ("clap", "👏"), ("clapping", "👏"), ("ok", "👌"), ("okay", "👌"),
        ("rocket", "🚀"), ("hundred", "💯"), ("100", "💯"), ("eyes", "👀"), ("thinking", "🤔"), ("cool", "😎"),
        ("heart eyes", "😍"), ("kiss", "😘"), ("angry", "😠"), ("shocked", "😮"), ("star", "⭐"), ("check", "✅"), ("tick", "✅"),
    ]
    private static let emojiCommand: NSRegularExpression = {
        let names = emoji.map(\.0).sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return rx("(?<![\\p{L}])(" + names + ")[ -]?(?:emoji|emojis|imoji)(?![\\p{L}])")
    }()
    private static let sendCommand = rx(#"(?:^|[\s,.]+)(?:and\s+)?(?:send it|send|bhej do|भेज दो|सेंड)[\s.!।]*$"#)

    /// Spoken commands: "new line" (a blank line), "new paragraph", "heart emoji".
    static func applyCommands(_ text: String) -> String {
        var s = text
        s = replace(newParagraph, in: s, with: "\n\n")
        // A blank line between paragraphs reads better in chats and email than a bare return.
        s = replace(newLine, in: s, with: "\n\n")
        let ns = s as NSString
        for m in emojiCommand.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if let e = emoji.first(where: { $0.0 == name })?.1, let r = Range(m.range, in: s) { s.replaceSubrange(r, with: e) }
        }
        return s
    }

    /// "…see you at 5 send" -> ("…see you at 5", true)
    static func stripSend(_ text: String) -> (String, Bool) {
        guard matches(sendCommand, text) else { return (text, false) }
        let stripped = replace(sendCommand, in: text, with: "")
        return stripped.trimmingCharacters(in: .whitespaces).isEmpty ? (text, false) : (stripped, true)
    }

    // MARK: Cleanup

    private static let englishFillers = rx(#"(?<![\p{L}\p{M}])(?:u+m+|u+h+|e+r+m+|e+r+|h+m+|m+h+m+|u+h+m+|m{2,}|a+h+|e+h+)(?![\p{L}\p{M}])[,.…]?\s*"#)
    /// The Hindi recognizer writes filler sounds in capitals ("UHH", "UNN", "HMM"). Case-sensitive on purpose.
    private static let capsFillers = try! NSRegularExpression(pattern: #"(?<![\p{L}])(?:U+H+|U+N+|U+M+|H+M+|A+H+|E+H+|M{2,})(?![\p{L}])[,.]?\s*"#)
    private static let hindiFillers = rx(#"(?<![\p{L}\p{M}])(?:उम्म?|अम्म?|हम्म|अं|उह)(?![\p{L}\p{M}])[,।]?\s*"#)
    // "I I think" -> "I think". Words people repeat on purpose are left alone.
    private static let stutter = rx(#"(?<![\p{L}\p{M}'])([\p{L}']+)(?:[\s,]+\1)+(?![\p{L}\p{M}'])"#)
    private static let keepRepeats: Set<String> = ["very", "really", "so", "no", "bye", "ha", "haha", "go", "yeah", "okay", "please", "had", "that"]
    private static let spaceBeforePunct = rx(#"[ \t]+([,.!?;:।])"#)
    private static let multiSpace = rx(#"[ \t]{2,}"#)
    private static let spaceAroundNewline = rx(#"[ \t]*\n[ \t]*"#)
    private static let lowerI = rx(#"(?<![\p{L}])i(?=['’ ]|$)"#)

    /// Cleans text in the language it was spoken in, before any translation.
    /// `language` is a language code like "en" or "hi".
    static func clean(_ text: String, language: String) -> String {
        var s = Settings.shared.voiceCommands ? applyCommands(text) : text
        s = replace(hindiFillers, in: s, with: "")
        s = capsFillers.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        s = replace(englishFillers, in: s, with: "")
        // Repeats are often intentional outside English ("dheere dheere", "kabhi kabhi").
        if language == "en" { s = removeStutters(s) }
        return tidy(s, english: LanguageCatalog.isLatin(s))
    }

    /// Final polish of English output: spacing, "i" -> "I", sentence capitals.
    static func tidy(_ text: String, english: Bool) -> String {
        var s = text
        s = replace(spaceBeforePunct, in: s, with: "$1")
        s = replace(multiSpace, in: s, with: " ")
        s = replace(spaceAroundNewline, in: s, with: "\n")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip punctuation a removed filler can leave at the start ("Um, hello" -> ", hello").
        while let first = s.first, ",.;:".contains(first) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        if english {
            s = replace(lowerI, in: s, with: "I")
            s = capitalizeSentences(s)
        }
        return s
    }

    /// Cheap check for spoken self-corrections that need a smarter rewrite.
    private static let correctionCue = rx(#"(?<![\p{L}])(?:no,? wait|wait,? no|no,? no|actually|i mean|sorry,|or rather|scratch that|not exactly|correction)(?![\p{L}])"#)
    static func needsSmartCleanup(_ english: String) -> Bool { matches(correctionCue, english) }

    static func isMostlyDevanagari(_ text: String) -> Bool {
        var deva = 0, latin = 0
        for scalar in text.unicodeScalars {
            if (0x0900...0x097F).contains(scalar.value) { deva += 1 }
            else if scalar.properties.isAlphabetic && scalar.isASCII { latin += 1 }
        }
        return deva > latin
    }

    // MARK: Helpers

    private static func removeStutters(_ s: String) -> String {
        let ns = s as NSString
        var result = s
        for m in stutter.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range(at: 1))
            if keepRepeats.contains(word.lowercased()) { continue }
            if let r = Range(m.range, in: result) { result.replaceSubrange(r, with: word) }
        }
        return result
    }

    private static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: ch.uppercased())
                capitalizeNext = false
                continue
            }
            out.append(ch)
            if ".!?\n".contains(ch) { capitalizeNext = true }
            else if !ch.isWhitespace && !"\"'“”‘’)".contains(ch) { capitalizeNext = false }
        }
        return out
    }

    static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
