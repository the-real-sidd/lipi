import Foundation

struct DictationRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case dictation, translation }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var text: String
    var app: String?
    var milliseconds: Int
    var words: Int { text.split { $0.isWhitespace }.count }
}

/// Recent dictations, kept only on this Mac (~/Library/Application Support/Lipi/history.json).
@MainActor
final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var records: [DictationRecord] = []
    private let url: URL
    private let limit = 300

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lipi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([DictationRecord].self, from: data) {
            records = saved
        }
    }

    func add(_ record: DictationRecord) {
        guard Settings.shared.keepHistory else { return }
        records.insert(record, at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    var wordsToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return records.filter { $0.date >= start }.reduce(0) { $0 + $1.words }
    }

    var totalWords: Int { records.reduce(0) { $0 + $1.words } }

    var medianMilliseconds: Int? {
        let times = records.filter { $0.kind == .dictation }.prefix(50).map(\.milliseconds).sorted()
        return times.isEmpty ? nil : times[times.count / 2]
    }

    private func save() {
        let snapshot = records
        let url = url
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}
