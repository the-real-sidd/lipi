import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var history = History.shared
    @ObservedObject private var catalog = LanguageCatalog.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if !model.isReady { setup }
                stats
                recent
            }
            .padding(32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private var speaks: String { LanguageCatalog.name(model.speechLocale) }
    private var types: String { model.outputLanguage.isEmpty ? "as spoken" : LanguageCatalog.name(model.outputLanguage) }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Brand.gradient)
                .overlay(
                    Text("लि")
                        .font(.system(size: 220, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.12))
                        .offset(x: 250, y: 10)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Hold").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(model.dictationKey.symbol)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .glassEffect(.regular.tint(.white.opacity(0.25)), in: .rect(cornerRadius: 10))
                    Text("and speak").font(.system(size: 26, weight: .bold, design: .rounded))
                }
                Text("You speak \(speaks). Lipi types \(types), right where your cursor is.")
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.9)
                HStack(spacing: 8) {
                    tip("⇧ while holding", "keep it as spoken")
                    tip("Double-tap \(model.translateKey.symbol)", "translate selection")
                }
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(26)
        }
        .frame(height: 210)
    }

    private func tip(_ key: String, _ what: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.system(size: 11, weight: .bold))
            Text(what).font(.system(size: 11)).opacity(0.85)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular.tint(.white.opacity(0.18)), in: .capsule)
    }

    private var setup: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Finish setting up").font(.system(size: 15, weight: .semibold))
                Text("Takes a minute. Everything runs on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                Divider().padding(.vertical, 6)
                SettingRow(title: "Microphone", detail: "Lipi listens only while you hold the key") {
                    StatusBadge(state: model.microphone, action: "Allow") { model.requestMicrophone() }
                }
                SettingRow(title: "Accessibility", detail: "Lets Lipi type into other apps") {
                    StatusBadge(state: model.accessibility, action: "Open Settings") { model.requestAccessibility() }
                }
                if model.accessibility != .ready {
                    AccessibilityHint()
                }
                SettingRow(title: "\(speaks) speech model", detail: "Downloaded and managed by macOS") {
                    StatusBadge(state: model.speechModels[model.speechLocale] ?? .missing, action: "Download") {
                        model.installSpeech(model.speechLocale)
                    }
                }
                if let pair = model.dictationPair {
                    let parts = pair.split(separator: ">").map(String.init)
                    SettingRow(title: "\(LanguageCatalog.name(parts[0])) → \(LanguageCatalog.name(parts[1])) translation",
                               detail: "macOS downloads both languages in one go and keeps them for all apps. It shows no size, and finishes in the background.") {
                        StatusBadge(state: model.translationModels[pair] ?? .missing, action: "Download") {
                            model.installTranslation(from: parts[0], to: parts[1])
                        }
                    }
                }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            stat("\(history.wordsToday)", "words today", "text.word.spacing")
            stat("\(history.totalWords)", "words dictated", "waveform")
            stat(history.medianMilliseconds.map { "\($0) ms" } ?? "–", "typical speed", "bolt.fill")
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).foregroundStyle(Brand.accent)
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent").font(.system(size: 15, weight: .semibold))
            if history.records.isEmpty {
                Card {
                    Text("Your dictations show up here. Hold \(model.dictationKey.symbol) anywhere and say something.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Card(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(history.records.prefix(25)) { record in
                            RecentRow(record: record)
                            if record.id != history.records.prefix(25).last?.id { Divider().padding(.leading, 70) }
                        }
                    }
                }
            }
        }
    }
}

private struct RecentRow: View {
    let record: DictationRecord
    @ViewState private var hovering = false
    @ViewState private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.text).font(.system(size: 13)).textSelection(.enabled).lineLimit(4)
                HStack(spacing: 6) {
                    if record.kind == .translation { Label("Translated", systemImage: "character.bubble").labelStyle(.titleAndIcon) }
                    if let app = record.app { Text(app) }
                    Text("· \(record.milliseconds) ms")
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if hovering {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                    copied = true
                }
                .buttonStyle(.glass).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0; if !$0 { copied = false } }
    }
}
