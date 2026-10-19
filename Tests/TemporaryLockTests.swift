import AppKit
import IOKit.ps

@MainActor
enum TemporaryLockTests {
    static func run() {
        L10n.select("en")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let initialPresentation = app.presentationOptions
        let controller = TemporaryLockController()
        var unlockCount = 0
        controller.onUnlock = { unlockCount += 1 }
        defer { controller.tearDown() }

        func visibleWindows() -> [TemporaryLockWindow] {
            app.windows.compactMap { $0 as? TemporaryLockWindow }.filter(\.isVisible)
        }
        func submit(_ window: TemporaryLockWindow, _ password: String) {
            let field = window.lockView.passwordField
            field.stringValue = password
            precondition(app.sendAction(field.action!, to: field.target, from: field))
        }

        precondition(!NSScreen.screens.isEmpty, "UI tests require an active macOS session")
        precondition(!controller.isLocked && visibleWindows().isEmpty, "Must start unlocked")
        controller.lock()
        precondition(controller.isLocked)
        precondition(visibleWindows().count == NSScreen.screens.count)
        for screen in NSScreen.screens {
            precondition(visibleWindows().contains { $0.frame == screen.frame })
        }
        precondition(app.presentationOptions.isEmpty, "Temporary lock must not enable kiosk presentation mode")
        precondition(!app.presentationOptions.contains(.disableForceQuit), "Preserve system exit mechanisms")
        let first = visibleWindows()[0]
        precondition(first.lockView.passwordField.placeholderString == "PIN")
        precondition(first.backgroundColor == .black && first.acceptsMouseMovedEvents)
        precondition(first.level == .screenSaver && first.canBecomeKey && !first.isRestorable)
        precondition(first.frame == first.screen?.frame, "The regular window must cover the entire desktop")
        precondition(first.collectionBehavior.contains(.canJoinAllApplications))
        precondition((first.lockView.passwordField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing == false)
        controller.lock()
        precondition(visibleWindows().contains(first), "Relocking must not create another window")

        // Empty, incomplete, and incorrect PINs must not dismiss the overlay.
        for password in ["", "12345", "1234567", "wrong"] {
            submit(first, password)
            precondition(controller.isLocked && unlockCount == 0)
            precondition(first.lockView.passwordField.stringValue.isEmpty)
        }
        first.cancelOperation(nil)
        precondition(controller.isLocked, "Escape must not unlock")

        // Display changes must rebuild all covering windows without unlocking.
        first.lockView.passwordField.stringValue = "123"
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        precondition(controller.isLocked && visibleWindows().count == NSScreen.screens.count)
        precondition(!visibleWindows().contains(first))
        precondition(first.lockView.passwordField.stringValue.isEmpty)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        precondition(controller.isLocked)

        // Submit through the real text field action and verify callback and UI cleanup.
        submit(visibleWindows()[0], "123456")
        precondition(!controller.isLocked && unlockCount == 1)
        precondition(visibleWindows().isEmpty)
        precondition(app.presentationOptions == initialPresentation)

        // The button must use the same PIN validation.
        controller.lock()
        let buttonWindow = visibleWindows()[0]
        let stack = buttonWindow.lockView.subviews.compactMap { $0 as? NSStackView }.first!
        let button = stack.arrangedSubviews.compactMap { $0 as? NSButton }.first!
        precondition(button.title == "Unlock")
        buttonWindow.lockView.passwordField.stringValue = "123456"
        button.performClick(nil)
        precondition(!controller.isLocked && unlockCount == 2)

        // Relock and teardown; a fresh controller starts unlocked.
        controller.lock()
        precondition(controller.isLocked)
        controller.tearDown()
        controller.tearDown()
        precondition(!controller.isLocked && visibleWindows().isEmpty && unlockCount == 2)
        precondition(app.presentationOptions == initialPresentation)
        precondition(!TemporaryLockController().isLocked)
        AppDelegate.testTemporaryLockActivityPolicy()
        AppDelegate.testEnglishInterface()
        testBatteryAndDimming()
        testSlackNotifications()
        testShortcutGuard()
        LocalizationTests.run()
        if ProcessInfo.processInfo.environment["WAKELOCK_TEST_HARDWARE"] == "1" {
            testPhysicalBrightness()
        }
        print("PASS: startup, display coverage, incorrect/correct PIN, Escape, display changes, wake, relock, cleanup")
    }
}

extension TemporaryLockTests {
    static func testShortcutGuard() {
        for key in [CGKeyCode(48), CGKeyCode(50), CGKeyCode(49)] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
            event.flags = .maskCommand
            precondition(LockShortcutGuard.blocks(event))
            event.flags = [.maskCommand, .maskShift]
            precondition(LockShortcutGuard.blocks(event))
            event.flags = []
            precondition(!LockShortcutGuard.blocks(event))
        }
        let systemLock = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
        systemLock.flags = [.maskCommand, .maskControl]
        precondition(!LockShortcutGuard.blocks(systemLock), "Preserve the real macOS lock shortcut")
        let guarder = LockShortcutGuard()
        guarder.start()
        guarder.stop()
        guarder.stop()
        print("PASS: app-switch shortcut guard without kiosk mode and preserved system lock")
    }

    static func testSlackNotifications() {
        let date = Date()
        precondition(SlackNotificationPreview.parse(sourceID: "mail", description: "Mail, About Slack, Example", date: date) == nil)
        precondition(SlackNotificationPreview.parse(sourceID: "fake", description: "Slackbot, A title, Example", date: date) == nil)
        precondition(SlackNotificationPreview.parse(sourceID: "empty", description: "Slack, , Example", date: date) == nil)
        let first = SlackNotificationPreview.parse(sourceID: "slack-1", description: "Slack, Zoë · #project, Hello, meeting at 15:00", date: date)!
        precondition(first.title == "Zoë · #project" && first.body == "Hello, meeting at 15:00")
        let monitor = SlackNotificationMonitor()
        var sounds = 0
        monitor.onNewNotification = { sounds += 1 }
        monitor.start()
        defer { monitor.stop() }
        monitor.consume([first], initial: true)
        precondition(monitor.previews.isEmpty && sounds == 0, "Do not display earlier notifications")
        for i in 2...6 {
            let next = SlackNotificationPreview.parse(sourceID: "slack-\(i)", description: "Slack, User \(i), Message \(i)", date: date)!
            monitor.consume([next])
            monitor.consume([next])
        }
        precondition(sounds == 5, "Do not play a sound for the same banner on every scan")
        precondition(monitor.previews.count == 3 && monitor.previews[0].title == "User 6")
        let retainedWindow = TemporaryLockWindow(screen: NSScreen.screens[0])
        retainedWindow.lockView.updateSlack(monitor.previews, status: "test")
        retainedWindow.lockView.layoutSubtreeIfNeeded()
        let panel = retainedWindow.lockView.subviews.first { $0.identifier?.rawValue == "slackPreviewPanel" }!
        precondition(retainedWindow.lockView.bounds.contains(panel.frame), "The Slack preview panel must remain on screen: \(panel.frame)")
        monitor.stop()
        monitor.consume([first])
        precondition(monitor.previews.isEmpty && sounds == 5, "Clear contents and stop monitoring on unlock")

        // The local test fills the preview panel and clears it on teardown.
        let controller = TemporaryLockController()
        controller.playSlackSound = false
        controller.showSlackTest()
        let window = NSApp.windows.compactMap { $0 as? TemporaryLockWindow }.first { $0.isVisible }!
        func strings(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(strings)
        }
        precondition(strings(window.lockView).contains("Slack Wake Lock · Local notification test"))
        controller.tearDown()
        precondition(!strings(window.lockView).contains("Slack Wake Lock · Local notification test"))
        retainedWindow.close()
        print("PASS: Slack-only filtering, message previews, old-banner skipping, deduplication/sound, memory cleanup, local test screen")
    }

    static func testBatteryAndDimming() {
        var description: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 35, kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsChargingKey: false,
        ]
        precondition(BatteryStatus.parse(description)?.text == "35% · On battery")
        description[kIOPSIsChargingKey] = true
        description[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        precondition(BatteryStatus.parse(description)?.text == "35% · Charging")
        description[kIOPSIsChargingKey] = false
        precondition(BatteryStatus.parse(description)?.text == "35% · Plugged in")
        description[kIOPSCurrentCapacityKey] = 100
        precondition(BatteryStatus.parse(description)?.text == "100% · Fully charged")
        description[kIOPSMaxCapacityKey] = 0
        precondition(BatteryStatus.parse(description) == nil)
        precondition(BatteryStatus.parse([:]) == nil)
        precondition(BatteryStatus.unavailable.text == "Battery information unavailable")

        var now: TimeInterval = 100
        var levels: [CGDirectDisplayID: Float] = [1: 0.7, 2: 0.02, 3: 0.6]
        var writes = 0
        let dimming = LockDimmingController(read: { levels[$0] }, write: { display, value in
            levels[display] = value
            writes += 1
            return true
        }, uptime: { now })
        let controller = TemporaryLockController(dimming: dimming)
        controller.lock()
        defer { controller.tearDown() }
        // Use fake displays instead of real hardware; one is already below 5%.
        dimming.updateDisplays([1, 2, 4]) // 4: unsupported external display
        precondition(writes == 0, "Do not change brightness when opening the lock")
        now += 4.99
        dimming.checkForInactivity()
        precondition(!dimming.isDimmed && writes == 0)
        now += 0.01
        dimming.checkForInactivity()
        precondition(dimming.isDimmed && levels[1] == 0.05 && levels[2] == 0.02)
        precondition(visibleLockViews().allSatisfy { $0.alphaValue == 0.35 })

        // Synthetic input must not count as real user activity.
        let cgEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: .zero, mouseButton: .left)!
        cgEvent.setIntegerValueField(.eventSourceUserData, value: Nudger.syntheticEventTag)
        let synthetic = NSEvent(cgEvent: cgEvent)!
        precondition(Nudger.isSyntheticInput(synthetic))
        dimming.handleInput(synthetic)
        precondition(dimming.isDimmed && levels[1] == 0.05)
        let realCGEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: .zero, mouseButton: .left)!
        let real = NSEvent(cgEvent: realCGEvent)!
        precondition(!Nudger.isSyntheticInput(real))
        dimming.handleInput(real)
        precondition(!dimming.isDimmed && levels[1] == 0.7)
        precondition(visibleLockViews().allSatisfy { $0.alphaValue == 1 })

        // Mouse movement extends the five-second inactivity deadline.
        now += 4
        dimming.userDidInteract()
        now += 1
        dimming.checkForInactivity()
        precondition(!dimming.isDimmed)
        now += 4
        dimming.checkForInactivity()
        precondition(dimming.isDimmed && levels[1] == 0.05)
        dimming.updateDisplays([1, 2, 3])
        precondition(levels[3] == 0.05, "Dim newly connected displays too")
        controller.tearDown()
        precondition(levels[1] == 0.7 && levels[2] == 0.02 && levels[3] == 0.6)
        let writesAfterStop = writes
        now += 10
        dimming.checkForInactivity()
        dimming.userDidInteract()
        precondition(writes == writesAfterStop, "Do not change brightness after unlock")
        print("PASS: battery status, black background, 5-second delay, real/synthetic input, repeated dimming, brightness restoration")
    }

    private static func visibleLockViews() -> [TemporaryLockView] {
        NSApp.windows.compactMap { $0 as? TemporaryLockWindow }.filter(\.isVisible).map(\.lockView)
    }

    static func testPhysicalBrightness() {
        var originals: [CGDirectDisplayID: Float] = [:]
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            if let value = DisplayBrightness.read(id) { originals[id] = value }
        }
        precondition(!originals.isEmpty, "A display with hardware brightness control is required")
        let dimming = LockDimmingController()
        dimming.start(displays: Array(originals.keys))
        defer { dimming.stop() }
        precondition(!dimming.isDimmed)
        RunLoop.main.run(until: Date().addingTimeInterval(5.2))
        var dimmedCorrectly = dimming.isDimmed
        for (id, original) in originals {
            dimmedCorrectly = dimmedCorrectly && abs((DisplayBrightness.read(id) ?? -1) - min(original, 0.05)) < 0.02
        }
        // Restore real brightness before asserting, even if verification fails.
        dimming.userDidInteract()
        var restoredCorrectly = !dimming.isDimmed
        for (id, original) in originals {
            restoredCorrectly = restoredCorrectly && abs((DisplayBrightness.read(id) ?? -1) - original) < 0.02
        }
        dimming.stop()
        precondition(dimmedCorrectly, "Hardware brightness did not decrease after five seconds")
        precondition(restoredCorrectly, "Hardware brightness was not restored")
        precondition(BatteryStatus.read().percentage != nil, "Could not read the actual battery percentage")
        print("PASS: real five-second timer, hardware dimming/restoration, and battery reading")
    }
}

// test.sh appends this to main.swift to test policy without exposing private state.
extension AppDelegate {
    static func testEnglishInterface() {
        let date = Fmt.stamp.date(from: "2026-10-19 10:00:00")!
        precondition(Fmt.pretty.string(from: date) == "Monday, October 19")
        precondition(Fmt.shortDay.string(from: date).contains("Oct 19"))
        precondition(Fmt.shortDay.string(from: date).contains("10:00"))
        precondition(durationText(65) == "1 min 5 s")
        precondition(durationText(3660) == "1 h 1 min")

        // Normalize the former built-in label for display without changing saved data.
        let legacyName = "\u{00D6}\u{011F}le molas\u{0131}"
        var config = Config()
        config.breaks = [Config.Break(name: legacyName, start: "12:00", end: "13:00")]
        let prayer = PrayerTimes()
        let plan = DayPlan(date: date, config: config, prayer: prayer)
        precondition(plan.breaks.first?.label == "Lunch break")
        precondition(plan.lines(config).contains { $0.contains("Lunch break") })
        precondition(config.breaks[0].name == legacyName)
        precondition(Config.Break(name: "My custom break", start: "12:00", end: "13:00").displayName == "My custom break")

        let delegate = AppDelegate()
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        precondition(titles.contains("🔒  Open temporary screen lock"))
        precondition(titles.contains("Edit settings (config.json)…"))
        precondition(titles.contains("Launch at login"))
        precondition(titles.contains("Quit Slack Wake Lock"))
        print("PASS: English dates, durations, menu, PIN controls, legacy lunch label, and preserved custom labels")
    }

    static func testTemporaryLockActivityPolicy() {
        let delegate = AppDelegate()
        delegate.config.friday.enabled = false // Check the schedule without network requests.
        delegate.lastRealActivity = .distantPast
        let cases: [(String, Bool)] = [
            ("2026-10-19 07:00:00", false), // before work
            ("2026-10-19 10:00:00", true),  // work
            ("2026-10-19 11:55:00", false), // waiting before a break
            ("2026-10-19 12:30:00", false), // break
            ("2026-10-19 20:00:00", false), // after work
            ("2026-10-24 10:00:00", false), // weekend
        ]
        for (stamp, expected) in cases {
            let date = Fmt.stamp.date(from: stamp)!
            precondition(delegate.snapshot(date).nudging == expected, "Preserve the normal schedule: \(stamp)")
        }
        delegate.temporaryLock.lock()
        for paused in [false, true] {
            delegate.pausedUntil = paused ? .distantFuture : nil
            for (stamp, _) in cases {
                let state = delegate.snapshot(Fmt.stamp.date(from: stamp)!)
                precondition(state.temporarilyLocked && state.nudging)
                precondition(delegate.statusText(state).contains("Temporary screen lock"))
            }
        }
        delegate.temporaryLock.tearDown()
        precondition(delegate.pausedUntil == .distantFuture, "The lock must preserve the existing pause")
        for (stamp, _) in cases {
            precondition(!delegate.snapshot(Fmt.stamp.date(from: stamp)!).nudging)
        }
        delegate.pausedUntil = nil
        for (stamp, expected) in cases {
            precondition(delegate.snapshot(Fmt.stamp.date(from: stamp)!).nudging == expected)
        }
        print("PASS: lock priority during work, breaks, off hours, and pauses; return to previous schedule")
    }
}
