import Foundation
import FoundationModels
import NaturalLanguage

/// Meeting summaries. Uses Apple Intelligence on-device when it's on (long meetings are
/// summarised in parts, then combined). Otherwise picks the key sentences and action items itself.
@MainActor
enum Summarizer {
    static func summarize(_ meeting: Meeting) async -> String {
        let transcript = meeting.transcriptText
        guard transcript.count > 40 else { return "Not much was said in this meeting." }
        let clock = Clock()
        if AIService.shared.isEnabled, let ai = try? await AIWriter.summarize(transcript, language: meeting.language) {
            Log.write("summary (Gemini) in \(clock.ms) ms")
            return ai
        }
        let model = SystemLanguageModel.default
        let supported = model.supportsLocale(Locale(identifier: meeting.locale))
        if model.isAvailable && supported, let ai = await aiSummary(transcript) {
            Log.write("summary (AI) in \(clock.ms) ms")
            return ai
        }
        let local = extractiveSummary(meeting)
        Log.write("summary (local) in \(clock.ms) ms")
        return local
    }

    private static let instructions = """
    You write meeting notes from a transcript. "Me" is the user, "Others" is everyone else on the call.
    Only use what is in the transcript. Never invent names, numbers or decisions.
    Use the same language as the transcript.
    """

    private static func aiSummary(_ transcript: String) async -> String? {
        // The on-device model has a small context window, so summarise in chunks first.
        let chunks = chunk(transcript, size: 6000)
        var partials: [String] = []
        for part in chunks {
            let session = LanguageModelSession(instructions: instructions)
            let prompt = "Summarise this part of a meeting as short bullet points: key points, decisions and action items.\n\n\(part)"
            guard let reply = try? await session.respond(to: prompt).content else { return nil }
            partials.append(reply)
        }
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Write the final meeting notes from these notes. Use exactly this format:
        ## Summary
        Two or three sentences.

        ## Key points
        - point

        ## Action items
        - who: what (write "None" if there are none)

        Notes:
        \(partials.joined(separator: "\n"))
        """
        return try? await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count > size, !current.isEmpty { chunks.append(current); current = "" }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: Local fallback

    private static let actionCue = TextCleanup.rx(
        #"(?<![\p{L}])(?:will|i'll|we'll|you'll|need to|needs to|have to|should|let's|going to|follow up|send|share|schedule|by (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|next week|eod|end of day)|deadline|karna hai|kar dena|bhej dena|karenge|karunga|karungi)(?![\p{L}])"#)

    private static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "for", "is", "are",
        "was", "were", "it", "that", "this", "i", "you", "we", "they", "he", "she", "be", "have", "has", "do", "with", "at",
        "as", "just", "like", "yeah", "okay", "ok", "um", "uh", "can", "will", "would", "think", "said", "get", "got", "also", "all", "about", "there", "here", "then", "than", "what", "your", "our", "their", "one", "two", "three", "new", "hai", "ki", "ka", "ko", "se", "mein", "aur", "to", "toh", "bhi"]

    private static let smallTalk = TextCleanup.rx(#"let's (?:get started|begin|start)|thanks everyone|thank you all"#)

    /// Repeated two-word phrases ("pricing page", "subject lines") make the best topic names.
    private static func topicPhrases(_ sentences: [String], fallback: [String: Int]) -> [String] {
        var counts: [String: Int] = [:]
        for s in sentences {
            let ws = s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            for i in 0..<max(ws.count - 1, 0) {
                let a = ws[i], b = ws[i + 1]
                guard a.count > 2, b.count > 2, !stopwords.contains(a), !stopwords.contains(b) else { continue }
                counts["\(a) \(b)", default: 0] += 1
            }
        }
        var phrases = counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key)
        // Drop single words already covered by a phrase.
        let covered = Set(phrases.flatMap { $0.split(separator: " ").map(String.init) })
        let singles = fallback.filter { $0.value >= 2 && !covered.contains($0.key) }.sorted { $0.value > $1.value }.map(\.key)
        if phrases.count < 3 { phrases += singles.prefix(3 - phrases.count) }
        return Array(phrases.prefix(3))
    }

    static func extractiveSummary(_ meeting: Meeting) -> String {
        var sentences: [(speaker: Meeting.Speaker, text: String)] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        for seg in meeting.segments {
            tokenizer.string = seg.text
            tokenizer.enumerateTokens(in: seg.text.startIndex..<seg.text.endIndex) { range, _ in
                let s = seg.text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if s.split(separator: " ").count >= 4 { sentences.append((seg.speaker, s)) }
                return true
            }
        }
        guard !sentences.isEmpty else { return "Not much was said in this meeting." }

        var freq: [String: Int] = [:]
        func words(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stopwords.contains($0) }
        }
        for s in sentences { for w in words(s.text) { freq[w, default: 0] += 1 } }
        let scored = sentences.enumerated().map { (i, s) -> (Int, Double) in
            let ws = words(s.text)
            let score = ws.reduce(0.0) { $0 + Double(freq[$1] ?? 0) } / Double(max(ws.count, 1)).squareRoot()
            return (i, score)
        }
        let keyCount = min(6, max(3, sentences.count / 8))
        let key = scored.sorted { $0.1 > $1.1 }.prefix(keyCount).map(\.0).sorted()
        let actions = sentences.filter { TextCleanup.matches(actionCue, $0.text) && !TextCleanup.matches(smallTalk, $0.text) }.prefix(6)

        let minutes = max(1, Int(meeting.duration / 60))
        let topics = topicPhrases(sentences.map(\.text), fallback: freq)
        var out = "## Summary\nA \(minutes)-minute \(meeting.app) meeting"
        if !topics.isEmpty {
            let list = topics.count > 1 ? topics.dropLast().joined(separator: ", ") + " and " + topics.last! : topics[0]
            out += " about \(list)"
        }
        out += ".\n\n## Key points\n"
        out += key.map { "- \(sentences[$0].text)" }.joined(separator: "\n")
        out += "\n\n## Action items\n"
        out += actions.isEmpty ? "- None found" : actions.map { "- \($0.speaker == .me ? "Me" : "Others"): \($0.text)" }.joined(separator: "\n")
        return out
    }
}
