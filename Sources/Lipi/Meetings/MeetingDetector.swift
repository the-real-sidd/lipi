import AppKit

/// Notices when a meeting app starts using the microphone, and when it stops.
/// Uses Core Audio's per-process input state: cheap (one query every 2 s), no extra permission.
@MainActor
final class MeetingDetector {
    struct App: Equatable { let bundle: String; let name: String }

    var onStart: ((App) -> Void)?
    var onEnd: ((App) -> Void)?

    private static let meetingApps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"), ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webex", "Webex"), ("Cisco-Systems.Spark", "Webex"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("net.whatsapp.WhatsApp", "WhatsApp"), ("desktop.WhatsApp", "WhatsApp"), ("com.hnc.Discord", "Discord"),
        ("ru.keepcoder.Telegram", "Telegram"), ("com.skype", "Skype"), ("com.ringcentral", "RingCentral"),
        ("com.google.Chrome", "Google Meet"), ("com.apple.Safari", "Google Meet"), ("com.apple.WebKit", "Google Meet"),
        ("company.thebrowser", "Google Meet"), ("com.microsoft.edgemac", "Google Meet"), ("com.brave.Browser", "Google Meet"),
        ("org.mozilla.firefox", "Google Meet"), ("com.vivaldi", "Google Meet"), ("com.operasoftware", "Google Meet"),
    ]

    private var timer: Timer?
    private var candidate: App?
    private var candidateSince: Date?
    private(set) var active: App?
    private var silentSince: Date?
    private var dismissed: App?

    /// Seconds a meeting app must hold the mic before we offer to take notes.
    var startDelay: TimeInterval = 6
    /// Seconds without the mic before we call the meeting over.
    var endDelay: TimeInterval = 12

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// The user said "not now": don't ask again until this meeting ends.
    func dismissCurrent() { dismissed = candidate ?? active }

    static func meetingApp(for bundle: String) -> App? {
        guard let match = meetingApps.first(where: { bundle.hasPrefix($0.prefix) }) else { return nil }
        return App(bundle: match.prefix, name: match.name)
    }

    private func poll() {
        let using = AudioDevices.processesUsingMicrophone().compactMap { Self.meetingApp(for: $0.bundle) }
        let now = Date()

        if let active {
            if using.contains(active) {
                silentSince = nil
            } else if let since = silentSince {
                if now.timeIntervalSince(since) >= endDelay {
                    self.active = nil
                    silentSince = nil
                    dismissed = nil
                    onEnd?(active)
                }
            } else {
                silentSince = now
            }
            return
        }

        guard let app = using.first else {
            candidate = nil
            candidateSince = nil
            dismissed = nil
            return
        }
        if app != candidate {
            candidate = app
            candidateSince = now
            return
        }
        if let since = candidateSince, now.timeIntervalSince(since) >= startDelay, app != dismissed {
            active = app
            candidate = nil
            candidateSince = nil
            onStart?(app)
        }
    }

    /// Tracks a meeting the user started by hand, so it still auto-stops.
    func adopt(_ app: App) { active = app; silentSince = nil }
    func release() { active = nil; silentSince = nil }
}
