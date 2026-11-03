import AppKit
import SwiftUI

/// Top-right glass card: "Meeting detected, take notes?" and, while recording, a small
/// timer with a quick "add a note" field and Stop.
@MainActor
final class MeetingPanelModel: ObservableObject {
    enum Mode: Equatable { case offer(String), recording, saved(String) }
    @Published var mode: Mode = .offer("")
    @Published var pointer = ""
    var onStart: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onStop: (() -> Void)?
    var onAddPointer: ((String) -> Void)?
    var onOpen: (() -> Void)?
}

struct MeetingPanelView: View {
    @ObservedObject var model: MeetingPanelModel
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.mode {
            case .offer(let app):
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic").font(.system(size: 22)).foregroundStyle(Brand.gradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In a meeting on \(app)?").font(.system(size: 13, weight: .semibold))
                        Text("Lipi can take notes and summarise it.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Take notes") { model.onStart?() }.buttonStyle(.glassProminent).tint(Brand.accent)
                    Button("Not now") { model.onDismiss?() }.buttonStyle(.glass)
                }
            case .recording:
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Taking notes · \(Meeting.clock(recorder.meeting?.duration ?? 0))")
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    Spacer()
                    Button(recorder.isFinishing ? "Saving…" : "Stop") { model.onStop?() }
                        .buttonStyle(.glassProminent).tint(.red).controlSize(.small).disabled(recorder.isFinishing)
                }
                Text(recorder.live.isEmpty ? "Listening…" : recorder.live)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    TextField("Add a note…", text: $model.pointer)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .onSubmit { model.onAddPointer?(model.pointer); model.pointer = "" }
                    Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(8)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
            case .saved(let title):
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notes saved").font(.system(size: 13, weight: .semibold))
                        Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { model.onOpen?() }.buttonStyle(.glassProminent).tint(Brand.accent).controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(10)
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MeetingPanel {
    let model = MeetingPanelModel()
    private let panel: NSPanel
    private var autoHide: DispatchWorkItem?

    init(recorder: MeetingRecorder) {
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: MeetingPanelView(model: model, recorder: recorder))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
    }

    func show(_ mode: MeetingPanelModel.Mode, hideAfter: Double? = nil) {
        autoHide?.cancel()
        model.mode = mode
        DispatchQueue.main.async { [self] in
            guard let view = panel.contentView, let screen = NSScreen.main?.visibleFrame else { return }
            let size = view.fittingSize
            panel.setFrame(NSRect(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 8,
                                  width: size.width, height: size.height), display: true)
            panel.orderFrontRegardless()
        }
        if let hideAfter {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            autoHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
        }
    }

    func hide() {
        autoHide?.cancel()
        panel.orderOut(nil)
    }
}
