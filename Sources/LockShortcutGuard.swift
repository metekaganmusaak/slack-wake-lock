import AppKit
import ApplicationServices

/// Blocks app-switch shortcuts without entering kiosk presentation mode.
/// Runs only during the lock; does not read or store typed text.
@MainActor
final class LockShortcutGuard {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    nonisolated static func blocks(_ event: CGEvent) -> Bool {
        guard event.flags.contains(.maskCommand) else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        return key == 48 || key == 50 || key == 49 // Cmd-Tab / Cmd-` / Spotlight (including Shift variants)
    }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        let guarder = Unmanaged<LockShortcutGuard>.fromOpaque(context).takeUnretainedValue()
                        if let tap = guarder.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    }
                    return Unmanaged.passUnretained(event)
                }
                return LockShortcutGuard.blocks(event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            Log.write("Temporary lock: could not start app-switch shortcut guard")
            return
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
}
