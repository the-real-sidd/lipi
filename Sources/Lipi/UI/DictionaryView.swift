import SwiftUI

extension Notification.Name {
    static let lipiDictionaryChanged = Notification.Name("LipiDictionaryChanged")
}

/// Friendly editor for ~/Library/Application Support/Lipi/dictionary.txt.
struct DictionaryView: View {
    struct Entry: Identifiable, Hashable {
        var id = UUID()
        var heard: String
        var typed: String   // empty = a word to teach
    }

    @ViewState private var entries: [Entry] = []
    @ViewState private var heard = ""
    @ViewState private var typed = ""
    @ViewState private var filter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Dictionary", subtitle: "Teach Lipi names and words, fix repeat mistakes, and save snippets you can say.")
                addCard
                list
            }
            .padding(32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .lipiDictionaryChanged)) { _ in load() }
    }

    private var addCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("Word, name, or what Lipi hears", text: $heard)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Type this instead (optional)", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.glassProminent).tint(Brand.accent)
                        .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Examples:  Siddhant   ·   inward → invite   ·   my email → you@example.com")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(entries.count) entries").font(.system(size: 13, weight: .semibold))
                Spacer()
                TextField("Search", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Card(padding: 4) {
                VStack(spacing: 0) {
                    let shown = entries.filter { filter.isEmpty || $0.heard.localizedCaseInsensitiveContains(filter) || $0.typed.localizedCaseInsensitiveContains(filter) }
                    if shown.isEmpty {
                        Text(entries.isEmpty ? "Nothing yet. Add your name first, it helps a lot." : "No matches")
                            .foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(shown) { entry in
                        HStack {
                            Image(systemName: entry.typed.isEmpty ? "person.text.rectangle" : "arrow.triangle.swap")
                                .foregroundStyle(Brand.accent).frame(width: 22)
                            Text(entry.heard).font(.system(size: 13, weight: .medium))
                            if !entry.typed.isEmpty {
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                Text(entry.typed.replacingOccurrences(of: "\n", with: " ⏎ ")).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { remove(entry) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        Divider().padding(.leading, 44)
                    }
                }
            }
            Button("Open dictionary file") { NSWorkspace.shared.open(PersonalDictionary.url) }
                .buttonStyle(.link).font(.system(size: 12))
            learned
        }
    }

    @ObservedObject private var memory = TranslationMemory.shared

    @ViewBuilder private var learned: some View {
        if !memory.fixes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Learned translation fixes").font(.system(size: 13, weight: .semibold)).padding(.top, 10)
                Text("Used when you speak about the same thing again.").font(.system(size: 11)).foregroundStyle(.secondary)
                Card(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(memory.fixes) { fix in
                            HStack {
                                Image(systemName: "sparkles").foregroundStyle(Brand.accent).frame(width: 22)
                                Text(fix.wrong).font(.system(size: 13)).strikethrough().foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                Text(fix.right).font(.system(size: 13, weight: .medium))
                                Text("· \(fix.anchors.prefix(3).joined(separator: ", "))")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                                Spacer()
                                Button { memory.remove(fix) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private func load() {
        PersonalDictionary().createIfMissing()
        let content = (try? String(contentsOf: PersonalDictionary.url, encoding: .utf8)) ?? ""
        entries = content.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            if let eq = line.range(of: "=") {
                return Entry(heard: line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces),
                             typed: line[eq.upperBound...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\n", with: "\n"))
            }
            return Entry(heard: line, typed: "")
        }
    }

    private func add() {
        let h = heard.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        entries.insert(Entry(heard: h, typed: typed.trimmingCharacters(in: .whitespaces)), at: 0)
        heard = ""
        typed = ""
        save()
    }

    private func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func save() {
        let body = entries.reversed().map { e in
            e.typed.isEmpty ? e.heard : "\(e.heard) = \(e.typed.replacingOccurrences(of: "\n", with: "\\n"))"
        }
        let text = PersonalDictionary.template + body.joined(separator: "\n") + "\n"
        try? text.write(to: PersonalDictionary.url, atomically: true, encoding: .utf8)
    }
}
