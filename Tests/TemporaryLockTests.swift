import AppKit
import IOKit.ps

@MainActor
enum TemporaryLockTests {
    static func run() {
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

        precondition(!NSScreen.screens.isEmpty, "UI testleri için açık bir macOS oturumu gerekli")
        precondition(!controller.isLocked && visibleWindows().isEmpty, "Başlangıç kilitsiz olmalı")
        controller.lock()
        precondition(controller.isLocked)
        precondition(visibleWindows().count == NSScreen.screens.count)
        for screen in NSScreen.screens {
            precondition(visibleWindows().contains { $0.frame == screen.frame })
        }
        precondition(app.presentationOptions.isEmpty, "Geçici kilit kiosk/sunum modunu etkinleştirmemeli")
        precondition(!app.presentationOptions.contains(.disableForceQuit), "Sistem çıkış yolu korunmalı")
        let first = visibleWindows()[0]
        precondition(first.backgroundColor == .black && first.acceptsMouseMovedEvents)
        precondition(first.level == .screenSaver && first.canBecomeKey && !first.isRestorable)
        precondition(first.frame == first.screen?.frame, "Normal pencere masaüstünü tamamen örtmeli")
        precondition(first.collectionBehavior.contains(.canJoinAllApplications))
        precondition((first.lockView.passwordField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing == false)
        controller.lock()
        precondition(visibleWindows().contains(first), "Tekrar açma yeni pencere oluşturmamalı")

        // Boş, kısmi ve yanlış şifreler kaplamayı kaldıramaz.
        for password in ["", "12345", "1234567", "wrong"] {
            submit(first, password)
            precondition(controller.isLocked && unlockCount == 0)
            precondition(first.lockView.passwordField.stringValue.isEmpty)
        }
        first.cancelOperation(nil)
        precondition(controller.isLocked, "Escape kilidi açmamalı")

        // Monitör değişimi kilidi açmadan tüm ekranları yeniden kaplamalı.
        first.lockView.passwordField.stringValue = "123"
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        precondition(controller.isLocked && visibleWindows().count == NSScreen.screens.count)
        precondition(!visibleWindows().contains(first))
        precondition(first.lockView.passwordField.stringValue.isEmpty)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        precondition(controller.isLocked)

        // Gerçek metin alanı eylemiyle doğru şifre, geri çağrı ve UI temizliği.
        submit(visibleWindows()[0], "123456")
        precondition(!controller.isLocked && unlockCount == 1)
        precondition(visibleWindows().isEmpty)
        precondition(app.presentationOptions == initialPresentation)

        // Düğme de aynı şifre kontrolünden geçmeli.
        controller.lock()
        let buttonWindow = visibleWindows()[0]
        let stack = buttonWindow.lockView.subviews.compactMap { $0 as? NSStackView }.first!
        let button = stack.arrangedSubviews.compactMap { $0 as? NSButton }.first!
        buttonWindow.lockView.passwordField.stringValue = "123456"
        button.performClick(nil)
        precondition(!controller.isLocked && unlockCount == 2)

        // Tekrar kilitleme ve uygulama kapanışı. Yeni controller kilitsiz başlar.
        controller.lock()
        precondition(controller.isLocked)
        controller.tearDown()
        controller.tearDown()
        precondition(!controller.isLocked && visibleWindows().isEmpty && unlockCount == 2)
        precondition(app.presentationOptions == initialPresentation)
        precondition(!TemporaryLockController().isLocked)
        AppDelegate.testTemporaryLockActivityPolicy()
        testBatteryAndDimming()
        testSlackNotifications()
        testShortcutGuard()
        if ProcessInfo.processInfo.environment["WAKELOCK_TEST_HARDWARE"] == "1" {
            testPhysicalBrightness()
        }
        print("PASS: başlangıç, ekran kapsamı, yanlış/doğru şifre, Escape, ekran değişimi, uyanma, tekrar kilitleme, temizlik")
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
        precondition(!LockShortcutGuard.blocks(systemLock), "Gerçek macOS kilidi korunmalı")
        let guarder = LockShortcutGuard()
        guarder.start()
        guarder.stop()
        guarder.stop()
        print("PASS: kiosk modu olmadan uygulama değiştirme kısayolları ve sistem kilidi ayrımı")
    }

    static func testSlackNotifications() {
        let date = Date()
        precondition(SlackNotificationPreview.parse(sourceID: "mail", description: "Mail, Slack hakkında, Örnek", date: date) == nil)
        precondition(SlackNotificationPreview.parse(sourceID: "fake", description: "Slackbot, Bir başlık, Örnek", date: date) == nil)
        precondition(SlackNotificationPreview.parse(sourceID: "empty", description: "Slack, , Örnek", date: date) == nil)
        let first = SlackNotificationPreview.parse(sourceID: "slack-1", description: "Slack, Ayşe · #proje, Merhaba, toplantı saat 15:00", date: date)!
        precondition(first.title == "Ayşe · #proje" && first.body == "Merhaba, toplantı saat 15:00")
        let monitor = SlackNotificationMonitor()
        var sounds = 0
        monitor.onNewNotification = { sounds += 1 }
        monitor.start()
        defer { monitor.stop() }
        monitor.consume([first], initial: true)
        precondition(monitor.previews.isEmpty && sounds == 0, "Önceki bildirimler gösterilmemeli")
        for i in 2...6 {
            let next = SlackNotificationPreview.parse(sourceID: "slack-\(i)", description: "Slack, Kullanıcı \(i), Mesaj \(i)", date: date)!
            monitor.consume([next])
            monitor.consume([next])
        }
        precondition(sounds == 5, "Aynı banner her taramada ses üretmemeli")
        precondition(monitor.previews.count == 3 && monitor.previews[0].title == "Kullanıcı 6")
        let retainedWindow = TemporaryLockWindow(screen: NSScreen.screens[0])
        retainedWindow.lockView.updateSlack(monitor.previews, status: "test")
        retainedWindow.lockView.layoutSubtreeIfNeeded()
        let panel = retainedWindow.lockView.subviews.first { $0.identifier?.rawValue == "slackPreviewPanel" }!
        precondition(retainedWindow.lockView.bounds.contains(panel.frame), "Slack önizleme alanı ekranda kalmalı: \(panel.frame)")
        monitor.stop()
        monitor.consume([first])
        precondition(monitor.previews.isEmpty && sounds == 5, "Kilit kalkınca içerik ve dinleme temizlenmeli")

        // Yerel test ekranı doğru alanı doldurmalı ve kapatınca içeriği temizlemeli.
        let controller = TemporaryLockController()
        controller.playSlackSound = false
        controller.showSlackTest()
        let window = NSApp.windows.compactMap { $0 as? TemporaryLockWindow }.first { $0.isVisible }!
        func strings(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(strings)
        }
        precondition(strings(window.lockView).contains("Slack Wake Lock · Yerel bildirim testi"))
        controller.tearDown()
        precondition(!strings(window.lockView).contains("Slack Wake Lock · Yerel bildirim testi"))
        retainedWindow.close()
        print("PASS: yalnızca Slack kaynak filtresi, mesaj önizlemesi, eski bildirimleri atlama, tekrar/ses kontrolü, bellek temizliği, yerel test ekranı")
    }

    static func testBatteryAndDimming() {
        var description: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 35, kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsChargingKey: false,
        ]
        precondition(BatteryStatus.parse(description)?.text == "%35 · Pille çalışıyor")
        description[kIOPSIsChargingKey] = true
        description[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        precondition(BatteryStatus.parse(description)?.text == "%35 · Şarj oluyor")
        description[kIOPSIsChargingKey] = false
        precondition(BatteryStatus.parse(description)?.text == "%35 · Prize bağlı")
        description[kIOPSCurrentCapacityKey] = 100
        precondition(BatteryStatus.parse(description)?.text == "%100 · Tam dolu")
        description[kIOPSMaxCapacityKey] = 0
        precondition(BatteryStatus.parse(description) == nil)
        precondition(BatteryStatus.parse([:]) == nil)
        precondition(BatteryStatus.unavailable.text == "Pil bilgisi alınamadı")

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
        // Gerçek donanım yerine sahte iki ekran: biri zaten %5'ten düşük.
        dimming.updateDisplays([1, 2, 4]) // 4: desteklenmeyen harici ekran
        precondition(writes == 0, "Kilit açılışında parlaklık değişmemeli")
        now += 4.99
        dimming.checkForInactivity()
        precondition(!dimming.isDimmed && writes == 0)
        now += 0.01
        dimming.checkForInactivity()
        precondition(dimming.isDimmed && levels[1] == 0.05 && levels[2] == 0.02)
        precondition(visibleLockViews().allSatisfy { $0.alphaValue == 0.35 })

        // Sanal hareket gerçek hareket sayılmamalı.
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

        // Fare oynadıkça 5 saniyelik süre uzar.
        now += 4
        dimming.userDidInteract()
        now += 1
        dimming.checkForInactivity()
        precondition(!dimming.isDimmed)
        now += 4
        dimming.checkForInactivity()
        precondition(dimming.isDimmed && levels[1] == 0.05)
        dimming.updateDisplays([1, 2, 3])
        precondition(levels[3] == 0.05, "Sonradan bağlanan ekran da kısılmalı")
        controller.tearDown()
        precondition(levels[1] == 0.7 && levels[2] == 0.02 && levels[3] == 0.6)
        let writesAfterStop = writes
        now += 10
        dimming.checkForInactivity()
        dimming.userDidInteract()
        precondition(writes == writesAfterStop, "Kilit kalkınca parlaklığa dokunulmamalı")
        print("PASS: pil durumları, siyah ekran, 5 sn gecikme, gerçek/sanal fare ayrımı, yeniden kısma, parlaklığı geri yükleme")
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
        precondition(!originals.isEmpty, "Donanım parlaklığı denetlenebilen bir ekran gerekli")
        let dimming = LockDimmingController()
        dimming.start(displays: Array(originals.keys))
        defer { dimming.stop() }
        precondition(!dimming.isDimmed)
        RunLoop.main.run(until: Date().addingTimeInterval(5.2))
        var dimmedCorrectly = dimming.isDimmed
        for (id, original) in originals {
            dimmedCorrectly = dimmedCorrectly && abs((DisplayBrightness.read(id) ?? -1) - min(original, 0.05)) < 0.02
        }
        // Doğrulama başarısız olsa da önce gerçek parlaklığı geri yükle.
        dimming.userDidInteract()
        var restoredCorrectly = !dimming.isDimmed
        for (id, original) in originals {
            restoredCorrectly = restoredCorrectly && abs((DisplayBrightness.read(id) ?? -1) - original) < 0.02
        }
        dimming.stop()
        precondition(dimmedCorrectly, "Donanım parlaklığı 5 sn sonunda azalmadı")
        precondition(restoredCorrectly, "Donanım parlaklığı geri yüklenemedi")
        precondition(BatteryStatus.read().percentage != nil, "Gerçek pil yüzdesi okunamadı")
        print("PASS: gerçek 5 sn zamanlayıcı, fiziksel parlaklık düşürme/geri yükleme ve pil okuma")
    }
}

// test.sh bu dosyayı main.swift'e ekler; private uygulama politikasını dışa açmadan doğrular.
extension AppDelegate {
    static func testTemporaryLockActivityPolicy() {
        let delegate = AppDelegate()
        delegate.config.friday.enabled = false // Ağ isteği olmadan planı kontrol et.
        delegate.lastRealActivity = .distantPast
        let cases: [(String, Bool)] = [
            ("2026-10-19 07:00:00", false), // mesai öncesi
            ("2026-10-19 10:00:00", true),  // mesai
            ("2026-10-19 11:55:00", false), // mola öncesi bekleme
            ("2026-10-19 12:30:00", false), // mola
            ("2026-10-19 20:00:00", false), // mesai sonrası
            ("2026-10-24 10:00:00", false), // hafta sonu
        ]
        for (stamp, expected) in cases {
            let date = Fmt.stamp.date(from: stamp)!
            precondition(delegate.snapshot(date).nudging == expected, "Normal plan korunmalı: \(stamp)")
        }
        delegate.temporaryLock.lock()
        for paused in [false, true] {
            delegate.pausedUntil = paused ? .distantFuture : nil
            for (stamp, _) in cases {
                let state = delegate.snapshot(Fmt.stamp.date(from: stamp)!)
                precondition(state.temporarilyLocked && state.nudging)
                precondition(delegate.statusText(state).contains("Geçici ekran kilidi"))
            }
        }
        delegate.temporaryLock.tearDown()
        precondition(delegate.pausedUntil == .distantFuture, "Kilit mevcut duraklatmayı değiştirmemeli")
        for (stamp, _) in cases {
            precondition(!delegate.snapshot(Fmt.stamp.date(from: stamp)!).nudging)
        }
        delegate.pausedUntil = nil
        for (stamp, expected) in cases {
            precondition(delegate.snapshot(Fmt.stamp.date(from: stamp)!).nudging == expected)
        }
        print("PASS: mesai, mola, mesai dışı ve duraklatma sırasında kilit önceliği ve eski plana dönüş")
    }
}
