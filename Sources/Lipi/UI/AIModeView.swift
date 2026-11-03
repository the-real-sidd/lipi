import AppKit
import SwiftUI

/// "AI mode": two steps to connect a free Gemini key from Google AI Studio.
struct AIModeCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var ai = AIService.shared
    @ViewState private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(Brand.gradient)
                        Text("AI mode").font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Recommended")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Brand.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(Brand.accent)
                    }
                    Text("Wispr-level cleanup (fillers, self-corrections, punctuation) and much better Hinglish → English, using Google's Gemini with your own free key. Needs internet. Only text is sent, never your voice. On Google's free plan what you send may be reviewed to improve their models, so turn AI mode off for private chats. If Gemini can't answer in time, Lipi uses the on-device path instead.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                    statusLine

                    Button { NSWorkspace.shared.open(AIService.keyPage) } label: {
                        Text("1.  Get a free key (opens Google)").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent).tint(Brand.accent).controlSize(.large)

                    Text("On that page: sign in, click Create API key, then Copy. Come back here.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    Button(action: paste) {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "Checking key…" : "2.  Paste key")
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent).tint(Brand.accent).controlSize(.large).disabled(busy)

                    if ai.hasKey {
                        Divider()
                        SettingRow(title: "Use AI mode") {
                            Toggle("", isOn: $model.aiEnabled).toggleStyle(.switch).labelsHidden()
                        }
                        Button("Remove key", role: .destructive) { ai.disconnect() }
                            .buttonStyle(.glass).frame(maxWidth: .infinity)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What AI mode changes").font(.system(size: 13, weight: .semibold))
                    example("um so I was uh thinking we ship Friday no wait Monday", "I was thinking we ship Monday.")
                    example("bhai kal office nahi aa paunga tabiyat thodi kharab hai", "Bro, I won't make it to the office tomorrow, I'm not feeling well.")
                }
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch ai.status {
        case .ready(let modelName):
            Label(model.aiEnabled ? "AI mode is on · key ending …\(keyEnding) · \(modelName)" : "AI mode is off · key ending …\(keyEnding)",
                  systemImage: model.aiEnabled ? "checkmark.circle.fill" : "pause.circle")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(model.aiEnabled ? .green : .secondary)
        case .checking:
            Label("Checking your key…", systemImage: "hourglass").font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .off:
            Label("Not set up yet · Lipi is using on-device cleanup", systemImage: "circle.dashed").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var keyEnding: String { String((Keychain.read() ?? "").suffix(4)) }

    private func example(_ said: String, _ typed: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("You say: \(said)").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Lipi types: \(typed)").font(.system(size: 12, weight: .medium))
        }
        .padding(.vertical, 4)
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        busy = true
        Task {
            if await ai.connect(with: text) { model.aiEnabled = true }
            busy = false
        }
    }
}
