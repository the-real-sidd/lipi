import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", languages = "Languages", notetaker = "Notetaker", setup = "Permissions", privacy = "Privacy"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .languages: "globe"
            case .notetaker: "record.circle"
            case .setup: "checkmark.shield"
            case .privacy: "lock"
            }
        }
    }

    @ObservedObject var model: AppModel
    @ObservedObject private var catalog = LanguageCatalog.shared
    @ViewState private var tab: Tab = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SETTINGS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        Label(t.rawValue, systemImage: t.icon)
                            .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(tab == t ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lipi \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Link(destination: URL(string: "https://instagram.com/the.real.sidd")!) {
                        Text("by @the.real.sidd").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Brand.accent)
                    .help("instagram.com/the.real.sidd")
                }
                .padding(10)
            }
            .padding(14)
            .frame(width: 190)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: tab.rawValue)
                    switch tab {
                    case .general: general
                    case .languages: languages
                    case .notetaker: notetaker
                    case .setup: setup
                    case .privacy: privacy
                    }
                }
                .padding(32)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    // MARK: General

    private var general: some View {
        Card {
            VStack(spacing: 0) {
                SettingRow(title: "Dictation shortcut", detail: "Hold \(model.dictationKey.symbol) and speak. Add ⇧ Shift to keep the language you spoke.") {
                    keyPicker($model.dictationKey)
                }
                Divider()
                SettingRow(title: "Translate shortcut", detail: "Select text anywhere, then double-tap \(model.translateKey.symbol).") {
                    keyPicker($model.translateKey)
                }
                if model.dictationKey == .fn || model.translateKey == .fn {
                    Text("For fn: in System Settings → Keyboard, set \"Press 🌐 key to\" to \"Do Nothing\".")
                        .font(.system(size: 11)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
                Divider()
                SettingRow(title: "Microphone", detail: currentMicName) {
                    Picker("", selection: $model.inputDeviceUID) {
                        Text("System default").tag("")
                        Divider()
                        ForEach(model.inputDevices) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 220)
                }
                Divider()
                SettingRow(title: "Theme") {
                    Picker("", selection: $model.theme) {
                        ForEach(Theme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                Divider()
                SettingRow(title: "Smart cleanup", detail: "Uses Apple Intelligence on this Mac to fix \"at two, no wait, three\" corrections.") {
                    Toggle("", isOn: $model.smartCleanup).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(title: "Learn from my corrections", detail: "When you fix a word Lipi typed, it remembers the fix for next time.") {
                    Toggle("", isOn: $model.learnCorrections).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(title: "Start sound") {
                    Toggle("", isOn: $model.playSounds).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(title: "Open at login") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    private var currentMicName: String {
        model.inputDevices.first { $0.id == model.inputDeviceUID }?.name ?? "System default"
    }

    private func keyPicker(_ binding: Binding<TriggerKey>) -> some View {
        Picker("", selection: binding) {
            ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden().frame(width: 220)
    }

    // MARK: Languages

    private var languages: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(spacing: 0) {
                    SettingRow(title: "I speak", detail: "Lipi listens for this language. Indian English and Hindi handle Hinglish.") {
                        LanguagePicker(title: "", selection: $model.speechLocale, choices: withSelection(catalog.speechLocales, model.speechLocale))
                    }
                    modelRow(model.speechLocale)
                    Divider()
                    SettingRow(title: "Type in", detail: "Lipi translates as you dictate. Hold ⇧ while speaking to skip it.") {
                        LanguagePicker(title: "", selection: $model.outputLanguage,
                                       choices: withSelection(catalog.translationLanguages, model.outputLanguage, allowEmpty: true),
                                       extra: [LanguageChoice(id: "", name: "Same as I speak")])
                    }
                    if let pair = model.dictationPair { pairRow(pair) }
                }
            }
            Card {
                VStack(spacing: 0) {
                    SettingRow(title: "Translate selected text from", detail: "Auto-detect works for Hindi, Hinglish, English and most others.") {
                        LanguagePicker(title: "", selection: $model.selectionSource,
                                       choices: withSelection(catalog.translationLanguages, model.selectionSource, allowEmpty: true),
                                       extra: [LanguageChoice(id: "auto", name: "Auto-detect")])
                    }
                    Divider()
                    SettingRow(title: "To", detail: "If the text is already in this language, Lipi translates it into the language you speak instead.") {
                        LanguagePicker(title: "", selection: $model.selectionTarget, choices: withSelection(catalog.translationLanguages, model.selectionTarget))
                    }
                    let source = model.selectionSource == "auto" ? model.spokenLanguage : model.selectionSource
                    if source != model.selectionTarget { pairRow("\(source)>\(model.selectionTarget)") }
                    HStack(spacing: 8) {
                        quick("Hindi → English", "hi", "en")
                        quick("English → Hindi", "en", "hi")
                        quick("Auto-detect", "auto", "en")
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func quick(_ title: String, _ from: String, _ to: String) -> some View {
        Button(title) { model.selectionSource = from; model.selectionTarget = to }
            .buttonStyle(.glass).controlSize(.small)
    }

    private func withSelection(_ choices: [LanguageChoice], _ id: String, allowEmpty: Bool = false) -> [LanguageChoice] {
        if id.isEmpty || id == "auto" || choices.contains(where: { $0.id == id }) { return choices }
        return [LanguageChoice(id: id, name: LanguageCatalog.name(id))] + choices
    }

    private func modelRow(_ locale: String) -> some View {
        HStack {
            Text("Speech model").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            StatusBadge(state: model.speechModels[locale] ?? .missing, action: "Download") { model.installSpeech(locale) }
        }
        .padding(.bottom, 10)
    }

    private func pairRow(_ pair: String) -> some View {
        let parts = pair.split(separator: ">").map(String.init)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(LanguageCatalog.name(parts[0])) → \(LanguageCatalog.name(parts[1])) model")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if model.translationModels[pair] != .ready {
                    Text("macOS downloads both languages together and finishes in the background.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            StatusBadge(state: model.translationModels[pair] ?? .missing, action: "Download") {
                model.installTranslation(from: parts[0], to: parts[1])
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: Notetaker

    private var notetaker: some View {
        Card {
            VStack(spacing: 0) {
                SettingRow(title: "Offer to take notes", detail: "When Zoom, Meet, Teams, FaceTime, Slack or WhatsApp starts using your mic.") {
                    Toggle("", isOn: $model.meetingAutoDetect).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(title: "Stop when the meeting ends", detail: "Notes are summarised and saved automatically.") {
                    Toggle("", isOn: $model.meetingAutoStop).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(title: "Meeting language", detail: "Pick Hindi for Hindi or Hinglish meetings.") {
                    LanguagePicker(title: "", selection: $model.meetingLocale, choices: withSelection(catalog.speechLocales, model.meetingLocale))
                }
                modelRow(model.meetingLocale)
                Divider()
                Text("Lipi transcribes your mic as \"Me\" and the call audio as \"Others\". macOS asks once for System Audio Recording. No audio is saved, only text.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Permissions & models

    private var setup: some View {
        Card {
            VStack(spacing: 0) {
                SettingRow(title: "Microphone", detail: "Only while you hold the key, or while taking notes") {
                    StatusBadge(state: model.microphone, action: "Allow") { model.requestMicrophone() }
                }
                Divider()
                SettingRow(title: "Accessibility", detail: "Lets Lipi type into other apps and read selected text") {
                    StatusBadge(state: model.accessibility, action: "Open Settings") { model.requestAccessibility() }
                }
                if model.accessibility != .ready {
                    AccessibilityHint()
                }
                Divider()
                SettingRow(title: "\(LanguageCatalog.name(model.speechLocale)) speech model") {
                    StatusBadge(state: model.speechModels[model.speechLocale] ?? .missing, action: "Download") { model.installSpeech(model.speechLocale) }
                }
                Divider()
                SettingRow(title: "Apple Intelligence", detail: "Optional: smart cleanup and better meeting summaries") {
                    StatusBadge(state: model.intelligence)
                }
            }
        }
    }

    // MARK: Privacy

    @ObservedObject private var history = History.shared

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                HStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 30)).foregroundStyle(Brand.gradient)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Everything stays on this Mac").font(.system(size: 15, weight: .semibold))
                        Text("Speech recognition, translation and summaries all run on-device. No account, no servers, no analytics.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            Card {
                VStack(spacing: 0) {
                    SettingRow(title: "Keep dictation history", detail: "\(history.records.count) saved") {
                        Toggle("", isOn: $model.keepHistory).toggleStyle(.switch).labelsHidden()
                    }
                    Divider()
                    SettingRow(title: "Clear history") {
                        Button("Clear", role: .destructive) { history.clear() }.buttonStyle(.glass)
                    }
                    Divider()
                    SettingRow(title: "Your data folder", detail: "Dictionary, history and meeting notes") {
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(PersonalDictionary.url.deletingLastPathComponent())
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
    }
}
