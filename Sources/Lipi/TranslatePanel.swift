import AppKit
import AVFoundation
import SwiftUI

/// Floating card that shows a translation of the selected text, near the mouse.
/// It never activates Lipi, so the app you were in keeps its selection for "Replace".
@MainActor
final class TranslateModel: ObservableObject {
    @Published var source = ""
    @Published var result = ""
    @Published var direction = ""
    @Published var isWorking = true
    @Published var error: String?
    var targetLanguage = "en-IN"
    var onReplace: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onSpeak: (() -> Void)?
}

struct TranslateView: View {
    @ObservedObject var model: TranslateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.direction, systemImage: "character.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.onClose?() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            Text(model.source)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Divider()
            Group {
                if model.isWorking {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Translating…").foregroundStyle(.secondary) }
                } else if let error = model.error {
                    Text(error).foregroundStyle(.orange)
                } else {
                    ScrollView {
                        Text(model.result)
                            .font(.system(size: 17))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Replace") { model.onReplace?() }
                    .keyboardShortcut(.defaultAction)
                Button("Copy") { model.onCopy?() }
                    .keyboardShortcut("c", modifiers: .command)
                Button { model.onSpeak?() } label: { Image(systemName: "speaker.wave.2.fill") }
                    .help("Read aloud")
                Spacer()
                Text("⏎ replace · esc close").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .disabled(model.isWorking || model.error != nil)
        }
        .padding(16)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@MainActor
final class TranslatePanel {
    let model = TranslateModel()
    private let panel: NSPanel
    private var clickMonitor: Any?
    private let speech = AVSpeechSynthesizer()

    init() {
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: TranslateView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        model.onClose = { [weak self] in self?.close() }
        model.onSpeak = { [weak self] in self?.speak() }
    }

    func show(source: String, direction: String) {
        model.source = source
        model.direction = direction
        model.result = ""
        model.error = nil
        model.isWorking = true
        place()
        panel.makeKeyAndOrderFront(nil)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func update(result: String?, error: String?) {
        model.result = result ?? ""
        model.error = error
        model.isWorking = false
        DispatchQueue.main.async { self.place(keepOrigin: true) }
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        speech.stopSpeaking(at: .immediate)
        panel.orderOut(nil)
    }

    private func speak() {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: model.result)
        utterance.voice = AVSpeechSynthesisVoice(language: model.targetLanguage)
        speech.speak(utterance)
    }

    private func place(keepOrigin: Bool = false) {
        guard let view = panel.contentView else { return }
        let size = view.fittingSize
        if keepOrigin {
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            panel.setFrame(frame, display: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 18)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        if origin.y < bounds.minY + 8 { origin.y = mouse.y + 18 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
