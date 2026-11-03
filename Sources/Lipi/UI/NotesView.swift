import SwiftUI
import Translation

struct NotesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject private var store = MeetingStore.shared
    @ViewState private var selection: Meeting.ID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 270)
            Divider()
            Group {
                if recorder.meeting != nil && selection == nil {
                    LiveNotesView(recorder: recorder) { model.onStopNotes?() }
                } else if let id = selection, let meeting = store.meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(meeting: meeting).id(meeting.id)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notes").font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
            }
            if recorder.meeting != nil {
                Button { selection = nil } label: {
                    HStack {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Taking notes…").font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .padding(10)
                    .glassEffect(.regular.tint(.red.opacity(0.15)), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else {
                Button { model.onStartNotes?() } label: {
                    Label("Start taking notes", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).tint(Brand.accent).controlSize(.large)
            }
            List(selection: $selection) {
                ForEach(store.meetings) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("\(m.start.formatted(date: .abbreviated, time: .shortened)) · \(max(1, Int(m.duration / 60))) min")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(m.id)
                    .contextMenu { Button("Delete", role: .destructive) { store.delete(m); if selection == m.id { selection = nil } } }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .padding(16)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 44)).foregroundStyle(Brand.gradient)
            Text("Your meeting notes live here").font(.system(size: 18, weight: .semibold))
            Text("Join a call on Zoom, Meet, Teams or FaceTime and Lipi will offer to take notes. It stops by itself when the call ends.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(40)
    }
}

// MARK: Live

struct LiveNotesView: View {
    @ObservedObject var recorder: MeetingRecorder
    var onStop: () -> Void
    @ViewState private var pointer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let meeting = recorder.meeting {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(.system(size: 20, weight: .bold, design: .rounded))
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text("Recording · \(Meeting.clock(meeting.duration))").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(recorder.isFinishing ? "Summarising…" : "Stop & summarise", action: onStop)
                        .buttonStyle(.glassProminent).tint(.red).disabled(recorder.isFinishing)
                }
                Card {
                    HStack {
                        TextField("Add your own note, press Return", text: $pointer)
                            .textFieldStyle(.plain).font(.system(size: 14))
                            .onSubmit { recorder.addPointer(pointer); pointer = "" }
                        Image(systemName: "plus.circle.fill").foregroundStyle(Brand.accent)
                    }
                }
                if !meeting.pointers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(meeting.pointers, id: \.self) { Label($0, systemImage: "pin.fill").font(.system(size: 13)) }
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(meeting.segments) { SegmentRow(segment: $0, text: $0.text) }
                            if !recorder.live.isEmpty {
                                Text(recorder.live).font(.system(size: 13)).foregroundStyle(.secondary).italic()
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: meeting.segments.count) { proxy.scrollTo("end") }
                }
            }
        }
        .padding(28)
    }
}

struct SegmentRow: View {
    let segment: Meeting.Segment
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(segment.speaker == .me ? "Me" : "Others")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(segment.speaker == .me ? Brand.accent : .indigo)
                .frame(width: 48, alignment: .leading)
            Text(Meeting.clock(segment.at)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 44, alignment: .leading)
            Text(text).font(.system(size: 13)).textSelection(.enabled)
        }
    }
}

// MARK: Saved meeting

struct MeetingDetailView: View {
    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript", notes = "My notes" }

    @ViewState var meeting: Meeting
    @ObservedObject private var catalog = LanguageCatalog.shared
    @ViewState private var tab: Tab = .summary
    @ViewState private var showing: String?          // translation language being shown, nil = original
    @ViewState private var translateConfig: TranslationSession.Configuration?
    @ViewState private var translatingTo: String?
    @ViewState private var pointer = ""
    @ViewState private var regenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320)
            ScrollView {
                Group {
                    switch tab {
                    case .summary: summary
                    case .transcript: transcript
                    case .notes: notes
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)
            }
        }
        .padding(28)
        .translationTask(translateConfig) { session in
            await translate(using: session)
        }
    }

    private var translated: Meeting.Translated? { showing.flatMap { meeting.translations[$0] } }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $meeting.title)
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .bold, design: .rounded))
                    .onSubmit(save)
                Text("\(meeting.start.formatted(date: .complete, time: .shortened)) · \(meeting.app) · \(max(1, Int(meeting.duration / 60))) min · \(LanguageCatalog.name(meeting.locale))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            GlassEffectContainer {
                HStack(spacing: 8) {
                    Menu {
                        Button("Original") { showing = nil }
                        Divider()
                        ForEach(catalog.translationLanguages.filter { $0.id != meeting.language }) { lang in
                            Button(meeting.translations[lang.id] != nil ? "\(lang.name) ✓" : lang.name) { requestTranslation(lang.id) }
                        }
                    } label: {
                        if let translatingTo {
                            Label("Translating to \(LanguageCatalog.name(translatingTo))…", systemImage: "character.bubble")
                        } else {
                            Label(showing.map { LanguageCatalog.name($0) } ?? "Translate", systemImage: "character.bubble")
                        }
                    }
                    .menuStyle(.button).buttonStyle(.glass).fixedSize()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(meeting.markdown(translation: showing), forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            MarkdownBlock(text: translated?.summary ?? meeting.summary ?? "No summary yet.")
            Button(regenerating ? "Summarising…" : "Regenerate summary") {
                regenerating = true
                Task {
                    meeting.summary = await Summarizer.summarize(meeting)
                    meeting.translations.removeAll()
                    showing = nil
                    regenerating = false
                    save()
                }
            }
            .buttonStyle(.glass).controlSize(.small).disabled(regenerating)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            if meeting.segments.isEmpty { Text("Nothing was transcribed.").foregroundStyle(.secondary) }
            ForEach(Array(meeting.segments.enumerated()), id: \.element.id) { i, seg in
                let text = translated.flatMap { $0.segments.indices.contains(i) ? $0.segments[i] : nil } ?? seg.text
                SegmentRow(segment: seg, text: text)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack {
                    TextField("Add a note, press Return", text: $pointer)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .onSubmit(addPointer)
                    Button(action: addPointer) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(Brand.accent)
                }
            }
            let points = translated?.pointers ?? meeting.pointers
            if points.isEmpty { Text("Add your own pointers here: decisions, reminders, anything.").foregroundStyle(.secondary) }
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                HStack(alignment: .top) {
                    Image(systemName: "pin.fill").foregroundStyle(Brand.accent).font(.system(size: 11))
                    Text(p).font(.system(size: 14)).textSelection(.enabled)
                    Spacer()
                    if showing == nil {
                        Button { meeting.pointers.remove(at: i); save() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func addPointer() {
        let t = pointer.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        meeting.pointers.append(t)
        meeting.translations.removeAll()
        pointer = ""
        save()
    }

    private func save() { MeetingStore.shared.save(meeting) }

    private func requestTranslation(_ target: String) {
        if meeting.translations[target] != nil { showing = target; return }
        translatingTo = target
        let config = TranslationSession.Configuration(source: Locale.Language(identifier: meeting.language), target: Locale.Language(identifier: target))
        if translateConfig?.target == config.target { translateConfig?.invalidate() } else { translateConfig = config }
    }

    private func translate(using session: TranslationSession) async {
        guard let target = translatingTo else { return }
        let lines = [meeting.summary ?? ""] + meeting.pointers + meeting.segments.map(\.text)
        let requests = lines.enumerated().compactMap { i, line in
            line.isEmpty ? nil : TranslationSession.Request(sourceText: line, clientIdentifier: String(i))
        }
        do {
            let responses = try await session.translations(from: requests)
            var out = lines
            for r in responses { if let id = r.clientIdentifier, let i = Int(id) { out[i] = r.targetText } }
            let p = meeting.pointers.count
            meeting.translations[target] = Meeting.Translated(summary: out[0], pointers: Array(out[1..<(1 + p)]), segments: Array(out[(1 + p)...]))
            showing = target
            save()
        } catch {
            Log.write("notes translation failed: \(error.localizedDescription)")
        }
        translatingTo = nil
    }
}

/// Renders the summary format: "## Heading", "- bullet" and plain lines.
struct MarkdownBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
                        .font(.system(size: 15, weight: .semibold)).padding(.top, 8)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Brand.accent).frame(width: 5, height: 5).offset(y: -2)
                        Text(inline(String(line.dropFirst(2)))).font(.system(size: 14)).textSelection(.enabled)
                    }
                } else if !line.isEmpty {
                    Text(inline(line)).font(.system(size: 14)).textSelection(.enabled)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
