import AppKit
import AVFoundation
import FoundationModels
import ServiceManagement
import Speech
import SwiftUI
import Translation

enum ItemState: Equatable {
    case ready, missing, working(Double?), unavailable(String)
}

/// The single source of truth the UI binds to. Writes go straight to Settings, then tell
/// the app controller so engines can re-warm for the new choice.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private let s = Settings.shared

    var onChange: (() -> Void)?
    var onStartNotes: (() -> Void)?
    var onStopNotes: (() -> Void)?
    let recorder = MeetingRecorder()

    // MARK: Preferences
    @Published var speechLocale: String { didSet { s.speechLocale = speechLocale; changed() } }
    @Published var outputLanguage: String { didSet { s.outputLanguage = outputLanguage; changed() } }
    @Published var selectionSource: String { didSet { s.selectionSource = selectionSource; changed() } }
    @Published var selectionTarget: String { didSet { s.selectionTarget = selectionTarget; changed() } }
    @Published var dictationKey: TriggerKey { didSet { s.dictationKey = dictationKey; changed() } }
    @Published var translateKey: TriggerKey { didSet { s.translateKey = translateKey; changed() } }
    @Published var inputDeviceUID: String { didSet { s.inputDeviceUID = inputDeviceUID; changed() } }
    @Published var theme: Theme { didSet { s.theme = theme; NSApp.appearance = theme.appearance } }
    @Published var smartCleanup: Bool { didSet { s.smartCleanup = smartCleanup } }
    @Published var playSounds: Bool { didSet { s.playSounds = playSounds } }
    @Published var keepHistory: Bool { didSet { s.keepHistory = keepHistory } }
    @Published var learnCorrections: Bool { didSet { s.learnCorrections = learnCorrections } }
    @Published var meetingAutoDetect: Bool { didSet { s.meetingAutoDetect = meetingAutoDetect; changed() } }
    @Published var meetingAutoStop: Bool { didSet { s.meetingAutoStop = meetingAutoStop } }
    @Published var meetingLocale: String { didSet { s.meetingLocale = meetingLocale; changed() } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var styles: [AppCategory: WritingStyle] = [:]

    // MARK: Status
    @Published var microphone: ItemState = .missing
    @Published var accessibility: ItemState = .missing
    @Published var speechModels: [String: ItemState] = [:]
    @Published var translationModels: [String: ItemState] = [:]
    @Published var intelligence: ItemState = .missing
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var translationRequest: TranslationSession.Configuration?
    @Published var section: MainSection = .home

    private var installing: Set<String> = []
    private var pendingPair: String?
    private var timer: Timer?

    private init() {
        speechLocale = s.speechLocale
        outputLanguage = s.outputLanguage
        selectionSource = s.selectionSource
        selectionTarget = s.selectionTarget
        dictationKey = s.dictationKey
        translateKey = s.translateKey
        inputDeviceUID = s.inputDeviceUID
        theme = s.theme
        smartCleanup = s.smartCleanup
        playSounds = s.playSounds
        keepHistory = s.keepHistory
        learnCorrections = s.learnCorrections
        meetingAutoDetect = s.meetingAutoDetect
        meetingAutoStop = s.meetingAutoStop
        meetingLocale = s.meetingLocale
        for c in AppCategory.allCases { styles[c] = s.style(for: c) }
    }

    private func changed() { onChange?() }

    func setStyle(_ style: WritingStyle, for category: AppCategory) {
        styles[category] = style
        s.setStyle(style, for: category)
    }

    // MARK: Readiness

    var spokenLanguage: String { LanguageCatalog.languageCode(ofLocale: speechLocale) }
    var dictationPair: String? { outputLanguage.isEmpty || outputLanguage == spokenLanguage ? nil : "\(spokenLanguage)>\(outputLanguage)" }

    var isReady: Bool {
        microphone == .ready && accessibility == .ready && speechModels[speechLocale] == .ready
            && (dictationPair.map { translationModels[$0] == .ready } ?? true)
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    private var refreshedOnce = false

    func refresh() async {
        let wasReady = isReady
        let wasTrusted = accessibility == .ready
        let wasMic = microphone == .ready
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .ready : .missing
        accessibility = Inserter.isTrusted ? .ready : .missing
        intelligence = Self.intelligenceState()
        if inputDevices.isEmpty { inputDevices = AudioDevices.inputs() }

        for locale in Set([speechLocale, meetingLocale]) where !installing.contains(locale) {
            speechModels[locale] = switch await SpeechEngine.status(locale) {
            case .installed: .ready
            case .downloading: .working(nil)
            case .unsupported: .unavailable("Not supported on this Mac")
            default: .missing
            }
        }
        var pairs: [(String, String)] = []
        if let pair = dictationPair { let p = pair.split(separator: ">"); pairs.append((String(p[0]), String(p[1]))) }
        let source = selectionSource == "auto" ? spokenLanguage : selectionSource
        if source != selectionTarget { pairs.append((source, selectionTarget)) }
        for (from, to) in pairs where pendingPair != "\(from)>\(to)" {
            translationModels["\(from)>\(to)"] = switch await Translator.status(from: from, to: to) {
            case .installed: .ready
            case .unsupported: .unavailable("This pair isn't supported")
            default: .missing
            }
        }
        // Re-warm engines only when something actually changed after launch.
        if refreshedOnce && (wasReady != isReady || wasTrusted != (accessibility == .ready) || wasMic != (microphone == .ready)) {
            onChange?()
        }
        refreshedOnce = true
    }

    static func intelligenceState() -> ItemState {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.deviceNotEligible): .unavailable("This Mac doesn't support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled): .unavailable("Turn on Apple Intelligence in System Settings")
        case .unavailable(.modelNotReady): .working(nil)
        default: .unavailable("Not available")
        }
    }

    // MARK: Actions

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in await self.refresh() } }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func requestAccessibility() {
        Inserter.promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func installSpeech(_ locale: String) {
        installing.insert(locale)
        speechModels[locale] = .working(0)
        Task {
            do {
                try await SpeechEngine.install(locale) { fraction in
                    Task { @MainActor in self.speechModels[locale] = .working(fraction) }
                }
                speechModels[locale] = .ready
            } catch {
                speechModels[locale] = .unavailable(error.localizedDescription)
            }
            installing.remove(locale)
            onChange?()
        }
    }

    /// Asks macOS to download a translation pair. macOS shows its own confirmation sheet.
    func installTranslation(from: String, to: String) {
        let key = "\(from)>\(to)"
        pendingPair = key
        translationModels[key] = .working(nil)
        translationRequest = TranslationSession.Configuration(source: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
    }

    func translationDownloadFinished() {
        pendingPair = nil
        translationRequest = nil
        Task { await refresh(); onChange?() }
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item error: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
