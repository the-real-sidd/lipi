import AppKit
import Foundation

/// A key you hold to dictate or double-tap to translate. Modifier-only, so it never blocks typing.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightOption, leftOption, rightCommand, rightControl, fn

    var id: String { rawValue }
    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .leftOption: 58
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }
    /// Device-specific bit in NSEvent.modifierFlags (tells left and right keys apart).
    var deviceMask: UInt {
        switch self {
        case .rightOption: 0x40
        case .leftOption: 0x20
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .fn: NSEvent.ModifierFlags.function.rawValue
        }
    }
    var genericFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        case .fn: .function
        }
    }
    var title: String {
        switch self {
        case .rightOption: "Right Option ⌥"
        case .leftOption: "Left Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case .rightControl: "Right Control ⌃"
        case .fn: "fn / Globe 🌐"
        }
    }
    var symbol: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .leftOption: "Left ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        case .fn: "fn"
        }
    }
}

enum WritingStyle: String, CaseIterable, Identifiable {
    case formal, casual, veryCasual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .formal: "Formal."
        case .casual: "Casual"
        case .veryCasual: "very casual"
        }
    }
    var detail: String {
        switch self {
        case .formal: "Caps + Punctuation"
        case .casual: "Caps + Less punctuation"
        case .veryCasual: "No caps + Less punctuation"
        }
    }
}

enum AppCategory: String, CaseIterable, Identifiable {
    case personal, work, email, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work messages"
        case .email: "Email"
        case .other: "Other"
        }
    }
    var headline: String {
        switch self {
        case .personal: "This style applies in personal messengers"
        case .work: "This style applies in work chat"
        case .email: "This style applies in email"
        case .other: "This style applies everywhere else"
        }
    }
    var defaultStyle: WritingStyle { self == .personal ? .casual : .formal }
}

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Persistent preferences. Everything is stored in UserDefaults on this Mac.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func string(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }
    private func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }

    /// BCP-47 locale for speech recognition, e.g. "hi-IN".
    var speechLocale: String {
        get { string("speechLocale", "hi-IN") }
        set { d.set(newValue, forKey: "speechLocale") }
    }
    /// Language to type in. Empty means "as spoken" (no translation).
    var outputLanguage: String {
        get { string("outputLanguage", "en") }
        set { d.set(newValue, forKey: "outputLanguage") }
    }
    /// Translate-selection source ("auto" = detect) and target.
    var selectionSource: String {
        get { string("selectionSource", "auto") }
        set { d.set(newValue, forKey: "selectionSource") }
    }
    var selectionTarget: String {
        get { string("selectionTarget", "en") }
        set { d.set(newValue, forKey: "selectionTarget") }
    }
    var dictationKey: TriggerKey {
        get { TriggerKey(rawValue: string("dictationKey", "")) ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "dictationKey") }
    }
    var translateKey: TriggerKey {
        get { TriggerKey(rawValue: string("translateKey", "")) ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "translateKey") }
    }
    /// Core Audio device UID. Empty means the system default input.
    var inputDeviceUID: String {
        get { string("inputDeviceUID", "") }
        set { d.set(newValue, forKey: "inputDeviceUID") }
    }
    var theme: Theme {
        get { Theme(rawValue: string("theme", "")) ?? .system }
        set { d.set(newValue.rawValue, forKey: "theme") }
    }
    func style(for category: AppCategory) -> WritingStyle {
        WritingStyle(rawValue: string("style.\(category.rawValue)", "")) ?? category.defaultStyle
    }
    func setStyle(_ style: WritingStyle, for category: AppCategory) {
        d.set(style.rawValue, forKey: "style.\(category.rawValue)")
    }
    var smartCleanup: Bool {
        get { bool("smartCleanup", true) }
        set { d.set(newValue, forKey: "smartCleanup") }
    }
    var playSounds: Bool {
        get { bool("playSounds", true) }
        set { d.set(newValue, forKey: "playSounds") }
    }
    var learnCorrections: Bool {
        get { bool("learnCorrections", true) }
        set { d.set(newValue, forKey: "learnCorrections") }
    }
    var keepHistory: Bool {
        get { bool("keepHistory", true) }
        set { d.set(newValue, forKey: "keepHistory") }
    }
    var meetingAutoDetect: Bool {
        get { bool("meetingAutoDetect", true) }
        set { d.set(newValue, forKey: "meetingAutoDetect") }
    }
    var meetingAutoStop: Bool {
        get { bool("meetingAutoStop", true) }
        set { d.set(newValue, forKey: "meetingAutoStop") }
    }
    var meetingLocale: String {
        get { string("meetingLocale", "en-IN") }
        set { d.set(newValue, forKey: "meetingLocale") }
    }
    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }
}
