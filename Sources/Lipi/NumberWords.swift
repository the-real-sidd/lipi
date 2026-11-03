import Foundation

/// Turns spoken numbers into digits: "one point five MB" -> "1.5 MB", "nine GB" -> "9 GB",
/// "twenty five" -> "25", "nine eight seven six" -> "9876".
/// Small numbers on their own stay as words ("this one", "no one", "two of us"), unless a unit
/// or a word like "at", "version" or "page" makes it clear they're numbers.
enum NumberWords {
    private static let small: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "lakh": 100_000, "lakhs": 100_000, "million": 1_000_000,
        "crore": 10_000_000, "crores": 10_000_000, "billion": 1_000_000_000,
    ]
    /// Words after a number that mean "this really is a number".
    private static let units: Set<String> = [
        "gb", "mb", "kb", "tb", "gig", "gigs", "percent", "per", "%", "am", "pm", "a.m.", "p.m.", "o'clock",
        "minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs", "second", "seconds", "sec", "secs",
        "day", "days", "week", "weeks", "month", "months", "year", "years", "km", "kms", "kg", "kgs", "cm", "mm",
        "ml", "litre", "litres", "liter", "liters", "rupees", "rupee", "rs", "dollars", "dollar", "bucks", "k",
        "x", "times", "inch", "inches", "feet", "ft", "pages", "people", "members", "items", "lakh", "lakhs",
        "crore", "crores", "star", "stars", "pm.", "am.", "gb.", "mb.",
    ]
    /// Words before a number that mean "this really is a number".
    private static let cues: Set<String> = [
        "at", "version", "number", "page", "step", "chapter", "room", "gate", "platform", "rs", "rupees",
        "plus", "minus", "times", "level", "round", "phase", "floor", "sector", "flat", "out",
    ]

    private static let token = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:[-'][A-Za-z]+)*|\S"#)

    /// The recognizer sometimes writes "one point five MB" as "one. 5 MB" or "1. 5 MB".
    private static let brokenDecimal = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\d])(zero|one|two|three|four|five|six|seven|eight|nine|\d+)\. (\d+)(?=\s?(?:%|[A-Za-z]{1,3}\b|percent|lakh|crore))"#)

    static func digitize(_ input: String) -> String {
        var text = input
        let digitsFor = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"]
        for m in brokenDecimal.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: text), let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) else { continue }
            let first = digitsFor[text[a].lowercased()] ?? String(text[a])
            text.replaceSubrange(whole, with: "\(first).\(text[b])")
        }
        let ns = text as NSString
        let matches = token.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let words = matches.map { ns.substring(with: $0.range) }
        var replacements: [(NSRange, String)] = []

        var i = 0
        while i < words.count {
            guard isNumberWord(words[i]) else { i += 1; continue }
            // Collect a run of number words, "and" inside hundreds, and "point" decimals.
            var j = i
            var run: [String] = []
            while j < words.count {
                let w = words[j].lowercased()
                if isNumberWord(w) { run.append(w); j += 1; continue }
                if w == "and", run.last == "hundred",
                   j + 1 < words.count, isNumberWord(words[j + 1]) { run.append(w); j += 1; continue }
                if w == "point", !run.isEmpty, j + 1 < words.count, isNumberWord(words[j + 1]) { run.append(w); j += 1; continue }
                break
            }
            // Keep Indian and big scales as words: "3 lakh", "2.5 crore", "5 million".
            var scaleWord: String?
            let bigScales: Set<String> = ["lakh", "lakhs", "crore", "crores", "million", "billion"]
            if let last = run.last, bigScales.contains(last), run.count > 1,
               run.dropLast().allSatisfy({ !bigScales.contains($0) && $0 != "thousand" }) {
                scaleWord = last
                run.removeLast()
            }
            if var (digits, isLarge) = value(of: run) {
                if let scaleWord { digits += " " + scaleWord; isLarge = true }
                let before = i > 0 ? words[i - 1].lowercased() : ""
                let after = j < words.count ? words[j].lowercased() : ""
                let hasDecimal = run.contains("point")
                if isLarge || hasDecimal || units.contains(after) || cues.contains(before) || after == "%" {
                    let range = NSUnionRange(matches[i].range, matches[j - 1].range)
                    replacements.append((range, digits))
                }
            }
            i = max(j, i + 1)
        }

        var out = text
        for (range, digits) in replacements.reversed() {
            if let r = Range(range, in: out) { out.replaceSubrange(r, with: digits) }
        }
        // "9 percent" -> "9%"
        out = out.replacingOccurrences(of: #"(\d) ?(?:percent|per cent)\b"#, with: "$1%", options: [.regularExpression, .caseInsensitive])
        return out
    }

    private static func isNumberWord(_ w: String) -> Bool {
        let w = w.lowercased()
        if w == "oh" { return false } // only valid inside digit strings, handled below
        if small[w] != nil || tens[w] != nil || scales[w] != nil { return true }
        let parts = w.split(separator: "-").map(String.init)
        return parts.count == 2 && tens[parts[0]] != nil && small[parts[1]].map { $0 < 10 } == true
    }

    /// Returns the digits and whether the number is "clearly a number" (10 or more, or a digit string).
    private static func value(of run: [String]) -> (String, Bool)? {
        var integerWords = run
        var decimalWords: [String] = []
        if let p = run.firstIndex(of: "point") {
            integerWords = Array(run[..<p])
            decimalWords = Array(run[(p + 1)...])
        }
        let flat = integerWords.filter { $0 != "and" }.flatMap { $0.split(separator: "-").map(String.init) }
        guard !flat.isEmpty else { return nil }

        // "nine eight seven six" -> a digit string (phone numbers, PINs, codes).
        if flat.count >= 3, flat.allSatisfy({ (small[$0] ?? 99) < 10 }), decimalWords.isEmpty {
            return (flat.map { String(small[$0]!) }.joined(), true)
        }
        // Several plain units in a row ("one two") isn't a single number; leave it.
        if flat.count >= 2, flat.allSatisfy({ (small[$0] ?? 99) < 10 }) { return nil }

        var total = 0, current = 0
        for w in flat {
            if let v = small[w] { current += v }
            else if let v = tens[w] { current += v }
            else if w == "hundred" { current = max(current, 1) * 100 }
            else if let v = scales[w] { total += max(current, 1) * v; current = 0 }
        }
        total += current
        var digits = String(total)
        if !decimalWords.isEmpty {
            let decimals = decimalWords.flatMap { $0.split(separator: "-").map(String.init) }
                .compactMap { w -> String? in
                    if let v = small[w] { return String(v) }
                    if let v = tens[w] { return String(v) }
                    return nil
                }
            guard !decimals.isEmpty else { return nil }
            digits += "." + decimals.joined()
        }
        return (digits, total >= 10)
    }
}
