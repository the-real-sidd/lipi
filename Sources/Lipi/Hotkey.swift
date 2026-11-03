import AppKit

enum DictationMode: Equatable {
    case asSpoken     // type what you said, cleaned up, in the language you spoke
    case translate    // type it in your "translate into" language
}

/// All shortcut logic, with no AppKit in it, so every key sequence can be unit tested.
///
///   Hold a dictation key            talk while held, text appears on release
///   Double-tap a dictation key      hands-free: keeps listening until you tap the key again
///   Esc                             cancel
///   Double-tap the selection key    translate the selected text
///   Any other key while holding     cancel (so ⌥-shortcuts and special characters still work)
struct GestureMachine {
    struct Keys: Equatable {
        var asSpoken: TriggerKey
        var translate: TriggerKey
        var selection: TriggerKey
    }

    enum Event {
        case down(TriggerKey, TimeInterval, otherModifiers: Bool)
        case up(TriggerKey, TimeInterval)
        case otherKey(escape: Bool, TimeInterval)
        case otherModifier(TimeInterval)
        case tick(TimeInterval)
    }

    enum Output: Equatable {
        case start(DictationMode)
        case lock(DictationMode)
        case finish
        case cancel
        case translateSelection
    }

    enum State: Equatable {
        case idle
        case holding(TriggerKey, DictationMode, since: TimeInterval)
        case maybeDoubleTap(TriggerKey, DictationMode, releasedAt: TimeInterval)
        case locked(TriggerKey, DictationMode)
        case ignoringUntilUp(TriggerKey)
    }

    var keys: Keys
    private(set) var state: State = .idle
    private var selectionDownAt: TimeInterval?
    private var lastSelectionTap: TimeInterval = -10

    static let tapLimit: TimeInterval = 0.25     // shorter than this is a tap, longer is a hold
    static let doubleTapGap: TimeInterval = 0.4  // second tap must start within this

    init(keys: Keys) { self.keys = keys }

    /// When a pending double-tap check expires, the caller should send `.tick`.
    var deadline: TimeInterval? {
        if case .maybeDoubleTap(_, _, let at) = state { return at + Self.doubleTapGap }
        return nil
    }

    var isHolding: Bool {
        if case .holding = state { return true }
        return false
    }

    private func mode(for key: TriggerKey) -> DictationMode? {
        if key == keys.asSpoken { return .asSpoken }
        if key == keys.translate { return .translate }
        return nil
    }

    mutating func handle(_ event: Event) -> [Output] {
        switch event {
        case .down(let key, let t, let others):
            return keyDown(key, t, others)
        case .up(let key, let t):
            return keyUp(key, t)
        case .otherKey(let escape, _):
            switch state {
            case .holding(let key, _, _):
                state = .ignoringUntilUp(key)
                return [.cancel]
            case .maybeDoubleTap:
                state = .idle
                return [.cancel]
            case .locked:
                if escape { state = .idle; return [.cancel] }
                return []   // typing during hands-free doesn't stop it
            case .idle, .ignoringUntilUp:
                return []
            }
        case .otherModifier:
            if case .holding(let key, _, _) = state {
                state = .ignoringUntilUp(key)
                return [.cancel]
            }
            return []
        case .tick(let t):
            if case .maybeDoubleTap(_, _, let at) = state, t - at >= Self.doubleTapGap {
                state = .idle
                return [.cancel]
            }
            return []
        }
    }

    private mutating func keyDown(_ key: TriggerKey, _ t: TimeInterval, _ others: Bool) -> [Output] {
        if let mode = mode(for: key) {
            switch state {
            case .idle:
                if others { state = .ignoringUntilUp(key); return [] } // someone else's shortcut
                state = .holding(key, mode, since: t)
                return [.start(mode)]
            case .maybeDoubleTap(let k, let m, let at):
                if k == key && t - at < Self.doubleTapGap {
                    state = .locked(key, m)
                    return [.lock(m)]
                }
                // A different dictation key: drop the pending tap and start fresh.
                state = .holding(key, mode, since: t)
                return [.cancel, .start(mode)]
            case .locked:
                state = .ignoringUntilUp(key)
                return [.finish]
            case .holding, .ignoringUntilUp:
                return []
            }
        }
        if key == keys.selection {
            if case .locked = state { return [] }
            selectionDownAt = others ? nil : t
        }
        return []
    }

    private mutating func keyUp(_ key: TriggerKey, _ t: TimeInterval) -> [Output] {
        switch state {
        case .holding(let k, let m, let since) where k == key:
            if t - since < Self.tapLimit {
                state = .maybeDoubleTap(key, m, releasedAt: t)
                return []
            }
            state = .idle
            return [.finish]
        case .ignoringUntilUp(let k) where k == key:
            state = .idle
            return []
        default:
            break
        }
        if key == keys.selection, mode(for: key) == nil, let down = selectionDownAt {
            selectionDownAt = nil
            guard t - down < Self.tapLimit else { return [] }
            if t - lastSelectionTap < Self.doubleTapGap + Self.tapLimit {
                lastSelectionTap = -10
                return [.translateSelection]
            }
            lastSelectionTap = t
        }
        return []
    }
}

/// Feeds real keyboard events into the GestureMachine.
@MainActor
final class Hotkey {
    var handler: ((GestureMachine.Output) -> Void)?
    private(set) var machine = GestureMachine(keys: .init(asSpoken: .rightOption, translate: .rightCommand, selection: .leftOption))
    private var monitors: [Any] = []
    private var downKeys: Set<TriggerKey> = []
    private var tickTimer: Timer?

    var keys: GestureMachine.Keys {
        get { machine.keys }
        set { machine.keys = newValue }
    }
    var isHolding: Bool { machine.isHolding }
    var isLocked: Bool { if case .locked = machine.state { return true }; return false }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Lets the app cancel hands-free from the outside (e.g. the overlay's stop).
    func reset() { machine = GestureMachine(keys: machine.keys); downKeys.removeAll() }

    private func send(_ event: GestureMachine.Event) {
        let outputs = machine.handle(event)
        outputs.forEach { handler?($0) }
        scheduleTick()
    }

    private func scheduleTick() {
        tickTimer?.invalidate()
        guard let deadline = machine.deadline else { return }
        let delay = max(0.01, deadline - ProcessInfo.processInfo.systemUptime)
        tickTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick(ProcessInfo.processInfo.systemUptime)) }
        }
    }

    private func handle(_ event: NSEvent) {
        let t = event.timestamp
        switch event.type {
        case .keyDown:
            send(.otherKey(escape: event.keyCode == 53, t))
        case .flagsChanged:
            let flags = event.modifierFlags
            let relevant = [machine.keys.asSpoken, machine.keys.translate, machine.keys.selection]
            if let key = relevant.first(where: { $0.keyCode == event.keyCode }) {
                let down = key == .fn ? flags.contains(.function) : (flags.rawValue & key.deviceMask) != 0
                if down && !downKeys.contains(key) {
                    downKeys.insert(key)
                    let others = !flags.intersection([.command, .control, .option, .shift]).subtracting(key.genericFlag).isEmpty
                    send(.down(key, t, otherModifiers: others))
                } else if !down && downKeys.contains(key) {
                    downKeys.remove(key)
                    send(.up(key, t))
                }
            } else {
                // Another modifier pressed while holding: it's a shortcut, not dictation.
                let pressed = !flags.intersection([.command, .control, .option, .shift]).isEmpty
                if pressed { send(.otherModifier(t)) }
            }
        default:
            break
        }
    }
}
