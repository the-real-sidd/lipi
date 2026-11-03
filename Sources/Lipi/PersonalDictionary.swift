import Foundation

/// ~/Library/Application Support/Lipi/dictionary.txt
///
///   wrong = right      always fix a word the recogniser gets wrong
///   Name               teach a name (also boosts recognition)
///   my email = a@b.c   say a phrase, get saved text (use \n for new lines)
final class PersonalDictionary {
    struct Rule { let regex: NSRegularExpression; let replacement: String }

    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lipi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.txt")
    }()

    private(set) var rules: [Rule] = []
    private(set) var words: [String] = []
    private var loadedDate: Date?

    static let template = """
    # Lipi personal dictionary. Changes apply to your next dictation.
    # Lines starting with # are ignored.
    #
    # Fix a word Lipi keeps getting wrong:
    #   inward = invite
    #
    # Teach a name or word (put it on its own line):
    #   Siddhant
    #
    # Say a short phrase and get saved text. Use \\n for a new line:
    #   my email = you@example.com
    #   my address = 12 MG Road\\nPune 411001

    """

    func createIfMissing() {
        if !FileManager.default.fileExists(atPath: Self.url.path) {
            try? Self.template.write(to: Self.url, atomically: true, encoding: .utf8)
        }
    }

    /// Reloads only when the file changed. Returns true if it did.
    @discardableResult
    func reloadIfNeeded() -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: Self.url.path)[.modificationDate]) as? Date
        if modified == loadedDate { return false }
        loadedDate = modified
        guard let content = try? String(contentsOf: Self.url, encoding: .utf8) else {
            rules = []; words = []
            return true
        }
        var rules: [Rule] = []
        var words: [String] = []
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let eq = line.range(of: "=") {
                let wrong = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\\n", with: "\n")
                guard !wrong.isEmpty else { continue }
                let pattern = "(?<![\\p{L}\\p{M}])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\p{L}\\p{M}])"
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    rules.append(Rule(regex: regex, replacement: NSRegularExpression.escapedTemplate(for: right)))
                }
                if !right.contains("\n"), right.count < 40 { words.append(right) }
            } else {
                words.append(line)
                let pattern = "(?<![\\p{L}\\p{M}])" + NSRegularExpression.escapedPattern(for: line) + "(?![\\p{L}\\p{M}])"
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    rules.append(Rule(regex: regex, replacement: NSRegularExpression.escapedTemplate(for: line)))
                }
            }
        }
        self.rules = rules
        self.words = Array(Set(words)).sorted()
        return true
    }

    /// Appends a learned fix ("wrong = right", or just the word when only its casing changed).
    /// Returns false if the dictionary already had it.
    @discardableResult
    func add(wrong: String, right: String) -> Bool {
        createIfMissing()
        let line = wrong.lowercased() == right.lowercased() ? right : "\(wrong) = \(right)"
        let content = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? Self.template
        let existing = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !existing.contains(line.lowercased()) else { return false }
        let updated = content.hasSuffix("\n") ? content + line + "\n" : content + "\n" + line + "\n"
        try? updated.write(to: Self.url, atomically: true, encoding: .utf8)
        reloadIfNeeded()
        return true
    }

    func apply(_ text: String) -> String {
        var s = text
        for rule in rules {
            s = rule.regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: rule.replacement)
        }
        return s
    }
}
