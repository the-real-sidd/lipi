import AVFoundation
import Speech

/// Records a meeting as notes: your mic ("Me") and the call audio ("Others") are transcribed
/// live, on-device, as two streams. Nothing is recorded to disk except the text.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var meeting: Meeting?
    @Published private(set) var live = ""
    @Published private(set) var isFinishing = false
    var isRecording: Bool { meeting != nil && !isFinishing }

    private let speech = SpeechEngine()
    private let mic = Mic()
    private let tap = SystemAudioTap()
    private var sessions: [SpeechEngine.Session] = []
    private var systemAudioWorks = false

    var onFinished: ((Meeting) -> Void)?

    func start(app: String, locale: String, micUID: String) async throws {
        guard meeting == nil else { return }
        guard let format = await speech.format(for: locale) else {
            throw NSError(domain: "Lipi", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Download the \(LanguageCatalog.name(locale)) speech model in Lipi settings first."])
        }
        let title = "\(app) meeting, \(Date().formatted(date: .abbreviated, time: .shortened))"
        meeting = Meeting(title: title, app: app, locale: locale)
        live = ""

        mic.select(deviceUID: micUID)
        let micStream = try mic.start(format: format)
        sessions.append(try await speech.begin(locale, input: micStream, useStandby: false,
            onPartial: { [weak self] text in self?.live = text },
            onFinal: { [weak self] text, at in self?.add(.me, text, at) }))

        do {
            let callStream = try tap.start(output: format)
            sessions.append(try await speech.begin(locale, input: callStream, useStandby: false,
                onPartial: { [weak self] text in self?.live = text },
                onFinal: { [weak self] text, at in self?.add(.others, text, at) }))
            systemAudioWorks = true
        } catch {
            systemAudioWorks = false
            Log.write("meeting: system audio unavailable, mic only (\(error.localizedDescription))")
        }
        Log.write("meeting started (\(app), \(locale), call audio: \(systemAudioWorks))")
    }

    func stop() async {
        guard var meeting, !isFinishing else { return }
        isFinishing = true
        mic.stop()
        tap.stop()
        for session in sessions { _ = await speech.finish(session) }
        sessions.removeAll()
        meeting = self.meeting ?? meeting
        meeting.end = Date()
        meeting.segments.sort { $0.at < $1.at }
        meeting.segments = Self.removeEcho(meeting.segments)
        meeting.summary = await Summarizer.summarize(meeting)
        MeetingStore.shared.save(meeting)
        Log.write("meeting saved: \(meeting.segments.count) segments, \(Int(meeting.duration)) s")
        self.meeting = nil
        isFinishing = false
        live = ""
        onFinished?(meeting)
    }

    func addPointer(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        meeting?.pointers.append(t)
    }

    private func add(_ speaker: Meeting.Speaker, _ text: String, _ at: Double) {
        meeting?.segments.append(Meeting.Segment(speaker: speaker, at: at, text: text))
    }

    /// Without headphones your mic also hears the other side. Drop "Me" lines that repeat
    /// an "Others" line from the same few seconds.
    static func removeEcho(_ segments: [Meeting.Segment]) -> [Meeting.Segment] {
        let others = segments.filter { $0.speaker == .others }
        guard !others.isEmpty else { return segments }
        func words(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
        let otherWords = others.map { ($0.at, words($0.text)) }
        return segments.filter { seg in
            guard seg.speaker == .me else { return true }
            let mine = words(seg.text)
            guard mine.count >= 3 else { return true }
            for (at, theirs) in otherWords where abs(at - seg.at) < 8 {
                let overlap = Double(mine.intersection(theirs).count) / Double(mine.count)
                if overlap > 0.6 { return false }
            }
            return true
        }
    }
}
