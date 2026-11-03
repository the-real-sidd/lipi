import Foundation
import Translation

/// On-device translation through Apple's Translation framework. The language models are
/// downloaded once by macOS (shared with Safari and the Translate app), so Lipi ships none.
@MainActor
final class Translator {
    private var sessions: [String: TranslationSession] = [:]

    nonisolated static func status(from: String, to: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
    }

    nonisolated static func isReady(from: String, to: String) async -> Bool {
        await status(from: from, to: to) == .installed
    }

    private func session(from: String, to: String) -> TranslationSession {
        let key = "\(from)>\(to)"
        if let s = sessions[key] { return s }
        let s = TranslationSession(installedSource: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
        sessions[key] = s
        return s
    }

    /// Translates line by line in one batch, so "new line" breaks survive translation.
    func translate(_ text: String, from: String, to: String) async throws -> String {
        try await translate(lines: text.components(separatedBy: "\n"), from: from, to: to).joined(separator: "\n")
    }

    /// Translates many strings in a single request (used for meeting notes).
    func translate(lines: [String], from: String, to: String) async throws -> [String] {
        if from == to { return lines }
        var requests: [TranslationSession.Request] = []
        for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            requests.append(TranslationSession.Request(sourceText: line, clientIdentifier: String(i)))
        }
        if requests.isEmpty { return lines }
        let responses = try await session(from: from, to: to).translations(from: requests)
        var out = lines.map { _ in "" }
        for r in responses {
            if let id = r.clientIdentifier, let i = Int(id) { out[i] = r.targetText }
        }
        return out
    }

    /// Loads a translation model into memory so the first real translation is fast.
    func warmUp(from: String, to: String) async {
        guard from != to, await Self.isReady(from: from, to: to) else { return }
        let clock = Clock()
        // A real sentence loads the whole model; a single word leaves the first dictation cold.
        let samples = ["hi": ["mujhe lagta hai ki hum kal milenge.", "मुझे लगता है कि हम कल मिलेंगे।"],
                       "en": ["I think we should meet tomorrow."]]
        for sample in samples[from] ?? ["Hello, how are you today?"] {
            _ = try? await translate(sample, from: from, to: to)
        }
        Log.write("translation \(from)>\(to) warm in \(clock.ms) ms")
    }

    func reset() { sessions.removeAll() }
}
