import Foundation

struct Meeting: Codable, Identifiable, Hashable {
    enum Speaker: String, Codable { case me, others }

    struct Segment: Codable, Hashable, Identifiable {
        var id = UUID()
        var speaker: Speaker
        var at: Double        // seconds from the start of the meeting
        var text: String
    }

    struct Translated: Codable, Hashable {
        var summary: String
        var pointers: [String]
        var segments: [String]
    }

    var id = UUID()
    var title: String
    var app: String
    var start = Date()
    var end: Date?
    var locale: String
    var segments: [Segment] = []
    var summary: String?
    var pointers: [String] = []
    var translations: [String: Translated] = [:]

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    var language: String { LanguageCatalog.languageCode(ofLocale: locale) }

    var transcriptText: String {
        segments.map { "\($0.speaker == .me ? "Me" : "Others"): \($0.text)" }.joined(separator: "\n")
    }

    func markdown(translation: String? = nil) -> String {
        let t = translation.flatMap { translations[$0] }
        var md = "# \(title)\n\n\(start.formatted(date: .abbreviated, time: .shortened)) · \(app) · \(Int(duration / 60)) min\n\n"
        if let summary = t?.summary ?? summary { md += summary + "\n\n" }
        let points = t?.pointers ?? pointers
        if !points.isEmpty { md += "## My notes\n" + points.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        md += "## Transcript\n"
        for (i, s) in segments.enumerated() {
            let text = t.map { $0.segments.indices.contains(i) ? $0.segments[i] : s.text } ?? s.text
            md += "**\(s.speaker == .me ? "Me" : "Others")** [\(Self.clock(s.at))] \(text)\n\n"
        }
        return md
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Meetings are saved as JSON files in ~/Library/Application Support/Lipi/Meetings.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()
    @Published private(set) var meetings: [Meeting] = []
    private let dir: URL

    private init() {
        dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lipi/Meetings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        meetings = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }

    func save(_ meeting: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        let url = dir.appendingPathComponent("\(meeting.id.uuidString).json")
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(meeting) { try? data.write(to: url, options: .atomic) }
        }
    }

    func delete(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(meeting.id.uuidString).json"))
    }
}
