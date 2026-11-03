import AppKit

/// Modifier-key gestures that never block typing:
///   hold the dictation key           dictate (translated to your "type in" language)
///   hold it + Shift                  dictate, keep the language you spoke
///   double-tap the translate key     translate the selected text
/// Pressing any other key while holding cancels, so normal shortcuts keep working.
final class Hotkey {
    enum Gesture {
        case holdBegan(keepAsSpoken: Bool)
        case modeChanged(keepAsSpoken: Bool)
        case holdEnded
        case tapped
        case doubleTapped
        case cancelled
    }

    var handler: ((Gesture) -> Void)?
    var dictationKey: TriggerKey = .rightOption
    var translateKey: TriggerKey = .rightOption

    private let escapeKey: UInt16 = 53
    private let tapLimit: TimeInterval = 0.22
    private let doubleTapGap: TimeInterval = 0.4

    private var downKey: TriggerKey?
    private var pressedAt: TimeInterval = 0
    private var lastTapAt: TimeInterval = 0
    private var lastTapKey: TriggerKey?
    private var cancelled = false
    private var monitors: [Any] = []

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func isDown(_ key: TriggerKey, _ flags: NSEvent.ModifierFlags) -> Bool {
        key == .fn ? flags.contains(.function) : (flags.rawValue & key.deviceMask) != 0
    }

    private func otherModifiers(_ flags: NSEvent.ModifierFlags, except key: TriggerKey) -> Bool {
        !flags.intersection([.command, .control, .option]).subtracting(key.genericFlag).isEmpty
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if downKey != nil && !cancelled {
                cancelled = true
                handler?(.cancelled)
            } else if event.keyCode == escapeKey {
                handler?(.cancelled)
            }
        case .flagsChanged:
            let flags = event.modifierFlags
            let keys = [dictationKey, translateKey].filter { $0.keyCode == event.keyCode }
            if let key = keys.first {
                let down = isDown(key, flags)
                if down && downKey == nil {
                    downKey = key
                    pressedAt = event.timestamp
                    cancelled = otherModifiers(flags, except: key)
                    if key == dictationKey && !cancelled {
                        handler?(.holdBegan(keepAsSpoken: flags.contains(.shift)))
                    }
                } else if !down && downKey == key {
                    downKey = nil
                    if cancelled { return }
                    let held = event.timestamp - pressedAt
                    if held < tapLimit {
                        if key == dictationKey { handler?(.tapped) }
                        if key == translateKey {
                            if lastTapKey == key && event.timestamp - lastTapAt < doubleTapGap {
                                lastTapAt = 0
                                handler?(.doubleTapped)
                            } else {
                                lastTapAt = event.timestamp
                                lastTapKey = key
                            }
                        }
                    } else if key == dictationKey {
                        handler?(.holdEnded)
                    }
                }
            } else if let key = downKey, !cancelled {
                if otherModifiers(flags, except: key) {
                    cancelled = true
                    handler?(.cancelled)
                } else if key == dictationKey {
                    handler?(.modeChanged(keepAsSpoken: flags.contains(.shift)))
                }
            }
        default:
            break
        }
    }
}
