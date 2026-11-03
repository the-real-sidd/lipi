import AppKit
import SwiftUI
import Translation

enum MainSection: String, CaseIterable, Identifiable {
    case home, notes, style, dictionary, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .notes: "Notes"
        case .style: "Style"
        case .dictionary: "Dictionary"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .notes: "record.circle"
        case .style: "textformat"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(MainSection.allCases) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .top) { brand }
            .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            Group {
                switch model.section {
                case .home: HomeView(model: model)
                case .notes: NotesView(model: model, recorder: model.recorder)
                case .style: StyleView(model: model)
                case .dictionary: DictionaryView()
                case .settings: SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 980, minHeight: 640)
        .translationTask(model.translationRequest) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                Log.write("translation download: \(error.localizedDescription)")
            }
            model.translationDownloadFinished()
        }
        .task { await LanguageCatalog.shared.load() }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
            Text("Lipi").font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.isReady ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(model.isReady ? "Ready · on-device" : "Setup needed")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = AppModel.shared

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ section: MainSection? = nil) {
        if let section { model.section = section }
        if window == nil {
            let host = NSHostingController(rootView: MainView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Lipi"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 1080, height: 720))
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("LipiMainV2")
            window = w
        }
        model.startPolling()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Log.write("main window closed")
        model.stopPolling()
        Settings.shared.onboarded = true
        // Back to a menu-bar-only app once the window is closed.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
