import AppKit
import SwiftUI

/// The small pill at the bottom of the screen: live level bars and the words as you say them.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case listening, working, done, message(String, isError: Bool) }
    @Published var phase: Phase = .listening
    @Published var mode = ""
    @Published var text = ""
    @Published var level: Float = 0
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                indicator.frame(width: 30, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.mode)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(line)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isError ? Color.orange : Color.primary)
                        // Live speech keeps the newest words visible; messages wrap and read in full.
                        .lineLimit(isMessage ? 3 : 2)
                        .truncationMode(isMessage ? .tail : .head)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400, alignment: .leading)
                        .animation(nil, value: model.text)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }

    private var isMessage: Bool {
        if case .message = model.phase { return true }
        return false
    }

    private var isError: Bool {
        if case .message(_, let e) = model.phase { return e }
        return false
    }

    private var line: String {
        switch model.phase {
        case .listening: return model.text.isEmpty ? "Listening…" : model.text
        case .working: return model.text.isEmpty ? "Working…" : model.text
        case .done: return model.text
        case .message(let m, _): return m
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let weights: [Float] = [0.45, 0.75, 1, 0.75, 0.45]
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: CGFloat(4 + 18 * model.level * weights[i]))
                }
            }
            .animation(.easeOut(duration: 0.08), value: model.level)
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18))
        case .message(_, let isError):
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? .orange : .secondary).font(.system(size: 16))
        }
    }
}

@MainActor
final class Overlay {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 130),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func show(_ phase: OverlayModel.Phase, mode: String? = nil, text: String? = nil) {
        hideWork?.cancel()
        if let mode { model.mode = mode }
        if let text { model.text = text }
        model.phase = phase
        if !panel.isVisible {
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func flash(_ message: String, isError: Bool = false, seconds: Double = 2.6) {
        show(.message(message, isError: isError))
        hide(after: seconds)
    }

    func hide(after delay: Double = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    if self.panel.alphaValue == 0 { self.panel.orderOut(nil); self.model.text = ""; self.model.level = 0 }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var isVisible: Bool { panel.isVisible }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
}
