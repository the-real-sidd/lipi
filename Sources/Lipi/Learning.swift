import AppKit
import ApplicationServices

/// Fixes for translations, learned when you correct Lipi's English. Each fix remembers some
/// of the words you spoke, so "condition → health" only applies when you talk about "tabiyat"
/// again, not to every sentence with "condition" in it.
@MainActor
final class TranslationMemory: ObservableObject {
    struct Fix: Codable, Hashable, Identifiable {
        var id = UUID()
        var wrong: String
        var right: String
        var anchors: [String]
    }

    static let shared = TranslationMemory()
    @Published private(set) var fixes: [Fix] = []
    private let url: URL

    private init() {
        url = PersonalDictionary.url.deletingLastPathComponent().appendingPathComponent("learned-translations.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Fix].self, from: data) { fixes = saved }
    }

    func add(wrong: String, right: String, source: String) {
        let anchors = Self.contentWords(source)
        guard !anchors.isEmpty else { return }
        fixes.removeAll { $0.wrong.lowercased() == wrong.lowercased() && Set($0.anchors) == Set(anchors) }
        fixes.insert(Fix(wrong: wrong, right: right, anchors: anchors), at: 0)
        save()
    }

    func remove(_ fix: Fix) {
        fixes.removeAll { $0.id == fix.id }
        save()
    }

    func apply(to text: String, source: String) -> String {
        guard !fixes.isEmpty else { return text }
        let spoken = Set(Self.contentWords(source))
        var out = text
        for fix in fixes {
            let needed = min(2, fix.anchors.count)
            guard spoken.intersection(fix.anchors).count >= needed else { continue }
            let pattern = "(?<![\\p{L}\\p{M}])" + NSRegularExpression.escapedPattern(for: fix.wrong) + "(?![\\p{L}\\p{M}])"
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = rx.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: fix.right))
        }
        return out
    }

    private static let filler: Set<String> = ["hai", "hain", "ki", "ka", "ke", "ko", "se", "mein", "main", "aur", "bhi", "toh", "to",
        "the", "and", "for", "that", "this", "with", "kya", "nahi", "nahin", "ho", "tha", "thi", "kar", "raha", "rahi"]

    static func contentWords(_ text: String) -> [String] {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && !filler.contains($0) }
        return Array(Set(words)).sorted()
    }

    private func save() {
        let snapshot = fixes, url = url
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// Watches the text box Lipi just typed into. If you change one to three words of what Lipi
/// typed (a name, a spelling, a word in a translation), it remembers the fix.
@MainActor
final class CorrectionLearner {
    private struct Watch {
        let element: AXUIElement
        let inserted: String
        let source: String
        let translated: Bool
        let started: Date
        var baseline: String?
    }

    var onLearned: ((String) -> Void)?
    var onDictionaryChanged: (() -> Void)?
    private let dictionary: PersonalDictionary
    private var watch: Watch?
    private var timer: Timer?
    private var activation: Any?

    init(dictionary: PersonalDictionary) {
        self.dictionary = dictionary
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check(final: true) }
        }
    }

    /// Call right after pasting `inserted` into the focused app.
    func begin(inserted: String, source: String, translated: Bool) {
        check(final: true)
        guard Settings.shared.learnCorrections, Inserter.isTrusted, let element = Self.focusedElement() else { return }
        watch = Watch(element: element, inserted: inserted.trimmingCharacters(in: .whitespacesAndNewlines),
                      source: source, translated: translated, started: Date())
        // Let the paste land, then remember what the box looked like.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, var w = self.watch, let value = Self.value(of: w.element), value.contains(w.inserted) else {
                self?.watch = nil
                return
            }
            w.baseline = value
            self.watch = w
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(final: false) }
        }
    }

    /// Compares the box with what Lipi typed. `final` ends the watch (new dictation, app switch).
    func check(final: Bool) {
        guard var w = watch else { return }
        defer {
            if final || Date().timeIntervalSince(w.started) > 120 { stop() } else { watch = w }
        }
        guard let baseline = w.baseline, let current = Self.value(of: w.element), current != baseline else { return }
        guard let (old, new) = Self.change(from: baseline, to: current, within: w.inserted) else {
            // Edits elsewhere (you kept typing): follow along so later fixes still line up.
            if current.contains(w.inserted) { w.baseline = current }
            return
        }
        learn(old: old, new: new, watch: w)
        // Keep watching the corrected text for more fixes.
        w = Watch(element: w.element, inserted: w.inserted.replacingOccurrences(of: old, with: new),
                  source: w.source, translated: w.translated, started: w.started, baseline: current)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        watch = nil
    }

    private func learn(old: String, new: String, watch: Watch) {
        let similarity = Self.similarity(old.lowercased(), new.lowercased())
        if old.lowercased() == new.lowercased() || similarity >= 0.45 {
            // A spelling or a name: fix it everywhere, and help recognition hear it.
            if dictionary.add(wrong: old, right: new) {
                onDictionaryChanged?()
                onLearned?("Learned: \(old) → \(new)")
                Log.write("learned spelling fix")
            }
        } else if watch.translated {
            TranslationMemory.shared.add(wrong: old, right: new, source: watch.source)
            onLearned?("Learned for next time: \(old) → \(new)")
            Log.write("learned translation fix")
        }
    }

    // MARK: Diffing

    /// The single word-level change between two versions of the text box, if it sits inside
    /// what Lipi typed and is 1 to 3 words on each side.
    static func change(from old: String, to new: String, within inserted: String) -> (String, String)? {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Grow to whole words on both sides.
        var start = prefix
        while start > 0, a[start - 1].isLetter || a[start - 1] == "'" { start -= 1 }
        var endA = a.count - suffix, endB = b.count - suffix
        while endA < a.count, a[endA].isLetter || a[endA] == "'" { endA += 1; endB += 1 }
        guard endB <= b.count, start <= endA, start <= endB else { return nil }
        let removed = String(a[start..<endA]).trimmingCharacters(in: .whitespaces)
        let added = String(b[start..<endB]).trimmingCharacters(in: .whitespaces)
        guard !removed.isEmpty, !added.isEmpty, removed != added,
              !removed.contains("\n"), !added.contains("\n"),
              (1...3).contains(removed.split(separator: " ").count), (1...3).contains(added.split(separator: " ").count),
              removed.count <= 40, added.count <= 40 else { return nil }
        // The change must be inside the text Lipi inserted.
        guard let insertedRange = old.range(of: inserted, options: .backwards) else { return nil }
        let lower = old.distance(from: old.startIndex, to: insertedRange.lowerBound)
        let upper = old.distance(from: old.startIndex, to: insertedRange.upperBound)
        guard start >= lower, endA <= upper else { return nil }
        return (removed, added)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = row
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: Accessibility

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func value(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        guard let text = value as? String, text.count < 20_000 else { return nil }
        return text
    }
}
