import SwiftUI

/// Shared look: soft cards for content, Liquid Glass for controls that float above it.
enum Brand {
    static let accent = Color(red: 0.98, green: 0.47, blue: 0.16)    // saffron
    static let accent2 = Color(red: 0.86, green: 0.18, blue: 0.42)   // rani pink
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A settings line: title and description on the left, a control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            control.fixedSize()
        }
        .padding(.vertical, 10)
    }
}

struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: .rect(cornerRadius: 6))
    }
}

struct StatusBadge: View {
    let state: ItemState
    var action: String?
    var perform: (() -> Void)?

    var body: some View {
        switch state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
        case .working(let fraction):
            if let fraction {
                ProgressView(value: fraction).frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
        case .missing:
            if let action, let perform {
                Button(action, action: perform).buttonStyle(.glassProminent).tint(Brand.accent)
            } else {
                Text("Missing").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .unavailable(let why):
            Text(why).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(maxWidth: 200, alignment: .trailing)
        }
    }
}

struct LanguagePicker: View {
    let title: String
    @Binding var selection: String
    let choices: [LanguageChoice]
    var extra: [LanguageChoice] = []

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(extra) { Text($0.name).tag($0.id) }
            if !extra.isEmpty { Divider() }
            ForEach(choices) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .frame(width: 200)
    }
}

/// Shown while Accessibility is off: explains the "switch is on but it still doesn't work" case.
struct AccessibilityHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Already switched on? macOS ties this permission to each version of Lipi, so an old switch can stay on for a previous copy. Fix clears it; then switch Lipi on again in the list.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Fix Accessibility") { Inserter.resetAccessibility() }
                    .buttonStyle(.glass).controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 6)
    }
}

/// SwiftUI's `@State` is a compiler macro in the macOS 27 SDK, and its plugin ships only with
/// Xcode. Using the property wrapper through an alias lets Lipi build with just the
/// Command Line Tools.
typealias ViewState = SwiftUI.State
