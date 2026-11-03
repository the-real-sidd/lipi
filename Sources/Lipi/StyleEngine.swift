import AppKit
import ApplicationServices

/// Picks a writing style from the app you're typing in, then applies it with plain rules
/// (no model, no delay). Like Wispr Flow, styles apply to text in Latin script.
enum StyleEngine {
    static let apps: [AppCategory: [String]] = [
        .personal: ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop",
                    "com.hnc.Discord", "com.apple.MobileSMS", "com.facebook.archon", "org.whispersystems.signal-desktop"],
        .work: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
                "com.linear", "com.atlassian.jira", "com.google.Chat"],
        .email: ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
                 "com.mimestream.Mimestream", "it.bloop.airmail2", "com.freron.MailMate"],
    ]

    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    private static let titleRules: [(AppCategory, [String])] = [
        (.email, ["gmail", "outlook", "inbox", "yahoo mail", "proton mail", "superhuman"]),
        (.personal, ["whatsapp", "telegram", "discord", "instagram", "messenger"]),
        (.work, ["slack", "microsoft teams", "linear", "jira", "google chat", "asana"]),
    ]

    static func currentCategory() -> AppCategory {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return .other }
        for (category, ids) in apps where ids.contains(bundle) { return category }
        if browsers.contains(bundle), let title = windowTitle(pid: app.processIdentifier)?.lowercased() {
            for (category, words) in titleRules where words.contains(where: title.contains) { return category }
        }
        return .other
    }

    private static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private static let greetingComma = TextCleanup.rx(#"^(hey|hi|hello|hii|ok|okay|so|yeah|yes|no|well|thanks|haan|arre|acha|accha|bhai|yaar)\s*,\s*"#)

    static func apply(_ style: WritingStyle, to text: String) -> String {
        guard !text.isEmpty, LanguageCatalog.isLatin(text) else { return text }
        switch style {
        case .formal:
            var s = text
            if let last = s.last, last.isLetter || last.isNumber { s.append(".") }
            return s
        case .casual:
            return lessPunctuation(text)
        case .veryCasual:
            return lowercaseSentenceStarts(lessPunctuation(text))
        }
    }

    private static func lessPunctuation(_ text: String) -> String {
        var s = TextCleanup.replace(greetingComma, in: text, with: "$1 ")
        let lines = s.components(separatedBy: "\n").map { line -> String in
            var l = line
            if l.hasSuffix("."), !l.hasSuffix("..") { l.removeLast() }
            return l
        }
        s = lines.joined(separator: "\n")
        return s
    }

    private static func lowercaseSentenceStarts(_ text: String) -> String {
        var out = ""
        var atStart = true
        var chars = Array(text)
        for i in chars.indices {
            let ch = chars[i]
            if atStart, ch.isLetter {
                // Keep "I" and all-caps words like "OK" or "PDF".
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let isPronounI = ch == "I" && !next.isLetter
                let isAcronym = next.isUppercase
                out.append(isPronounI || isAcronym ? ch : Character(ch.lowercased()))
                atStart = false
                continue
            }
            out.append(ch)
            if ".!?\n".contains(ch) { atStart = true } else if !ch.isWhitespace { atStart = false }
        }
        chars.removeAll()
        return out
    }
}
