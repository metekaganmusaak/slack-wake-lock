import AppKit
import IOKit.ps

/// Oturumu kilitlemeden masaüstünü örter. Durum yalnızca bellekte tutulur.
@MainActor
final class TemporaryLockController: NSObject {
    private(set) var isLocked = false
    var onUnlock: (() -> Void)?
    var playSlackSound = true

    private var windows: [TemporaryLockWindow] = []
    private var previousPresentation: NSApplication.PresentationOptions = []
    private var previousApplication: NSRunningApplication?
    private var keyMonitor: Any?
    private var clockTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private let dimming: LockDimmingController
    private let shortcuts = LockShortcutGuard()
    private let slackNotifications = SlackNotificationMonitor()
    private var slackStatus = "Slack bildirimleri bekleniyor"
    private var slackPreviews: [SlackNotificationPreview] = []

    init(dimming: LockDimmingController? = nil) {
        self.dimming = dimming ?? LockDimmingController()
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildWindows),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(bringForward),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    func lock() {
        guard !isLocked, !NSScreen.screens.isEmpty else { return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        previousPresentation = NSApp.presentationOptions
        isLocked = true
        NSApp.activate(ignoringOtherApps: true)
        // Kiosk/sunum modu bildirim teslimini etkileyebilir. Masaüstünü yalnızca
        // normal bir pencereyle ört; Dock/menü çubuğu bu pencerenin altında kalır.
        NSApp.presentationOptions = []
        shortcuts.start()

        // Uygulamanın kapanması/gizlenmesi için kullanılan normal kısayolları yut.
        // Sistem kilidi ve zorla çıkış gibi macOS güvenlik mekanizmaları korunur.
        let inputEvents: NSEvent.EventTypeMask = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: inputEvents) { [weak self] event in
            self?.dimming.handleInput(event)
            guard event.type == .keyDown else { return event }
            if event.keyCode == 53 { return nil } // Escape
            if event.modifierFlags.contains(.command) {
                let editingKeys = ["a", "c", "v", "x", "z"]
                if !editingKeys.contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
                    return nil
                }
            }
            return event
        }
        dimming.onChange = { [weak self] dimmed in
            for window in self?.windows ?? [] { window.lockView.alphaValue = dimmed ? 0.35 : 1 }
        }
        rebuildWindows()
        dimming.start(displays: displayIDs())
        startBatteryUpdates()
        slackNotifications.onUpdate = { [weak self] previews, status in
            guard let self, self.isLocked else { return }
            guard self.slackPreviews != previews || self.slackStatus != status else { return }
            self.slackStatus = status
            self.slackPreviews = previews
            for window in self.windows { window.lockView.updateSlack(previews, status: status) }
        }
        slackNotifications.onNewNotification = { [weak self] in
            guard let self, self.isLocked, self.playSlackSound else { return }
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        slackNotifications.start()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(updateClock),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// Yalnızca uygulama kapanırken kullanılır; yeniden açılışta kilit geri yüklenmez.
    func tearDown() {
        guard isLocked else { return }
        isLocked = false
        clockTimer?.invalidate()
        clockTimer = nil
        dimming.stop()
        shortcuts.stop()
        slackNotifications.stop()
        slackStatus = "Slack bildirimleri bekleniyor"
        slackPreviews.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSApp.presentationOptions = previousPresentation
        for window in windows {
            window.lockView.clearPassword()
            window.lockView.updateSlack([], status: "")
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    private func submit(_ password: String) -> Bool {
        guard isLocked, password == "123456" else { return false }
        tearDown()
        previousApplication?.activate(options: [])
        previousApplication = nil
        onUnlock?()
        return true
    }

    @objc private func rebuildWindows() {
        guard isLocked else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        // Yeni ekranlar kaplanana kadar eski pencereler görünür kalır.
        let oldWindows = windows
        windows = screens.map { screen in
            let window = TemporaryLockWindow(screen: screen)
            window.lockView.onSubmit = { [weak self] password in self?.submit(password) ?? false }
            window.lockView.alphaValue = dimming.isDimmed ? 0.35 : 1
            window.lockView.updateSlack(slackNotifications.previews, status: slackStatus)
            window.orderFrontRegardless()
            return window
        }
        for window in oldWindows {
            window.lockView.clearPassword()
            window.lockView.updateSlack([], status: "")
            window.orderOut(nil)
            window.close()
        }
        updateClock()
        updateBattery()
        dimming.updateDisplays(displayIDs())
        bringForward()
    }

    @objc private func bringForward() {
        guard isLocked else { return }
        for window in windows { window.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        // İmlecin bulunduğu monitörde şifre girişi hazır olsun.
        let window = windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.lockView.passwordField)
    }

    @objc private func updateClock() {
        let now = Date()
        for window in windows { window.lockView.updateClock(now) }
    }

    @objc private func didWake() {
        guard isLocked else { return }
        bringForward()
        dimming.userDidInteract()
    }

    private func displayIDs() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
    }

    private func startBatteryUpdates() {
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<TemporaryLockController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.updateBattery() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        updateBattery()
    }

    private func updateBattery() {
        guard isLocked else { return }
        let status = BatteryStatus.read()
        for window in windows { window.lockView.updateBattery(status) }
    }

    func showSlackTest() {
        lock()
        guard isLocked else { return }
        slackNotifications.consume([SlackNotificationPreview(sourceID: UUID().uuidString,
            title: "Slack Wake Lock · Yerel bildirim testi", body: "Slack önizleme alanı ve ek uyarı sesi testi. Gerçek bir Slack mesajı gönderilmedi.", receivedAt: Date())])
    }
}

@MainActor
final class TemporaryLockWindow: NSWindow {
    let lockView = TemporaryLockView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        isRestorable = false
        isOpaque = true
        backgroundColor = .black
        // Üstteki kaplama diğer uygulamaları örter; bildirimleri susturan kiosk
        // ayarları kullanılmaz. Slack banner'ları bu pencerenin içinde gösterilir.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        contentView = lockView
        initialFirstResponder = lockView.passwordField
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {} // Escape kilidi kapatmaz.
}

@MainActor
final class TemporaryLockView: NSView {
    let passwordField = NSSecureTextField()
    var onSubmit: ((String) -> Bool)?
    private let timeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: " ")
    private let batteryLabel = NSTextField(labelWithString: "")
    private let batteryIcon = NSImageView()
    private let slackStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)

        timeLabel.font = .systemFont(ofSize: 76, weight: .thin)
        dateLabel.font = .systemFont(ofSize: 18, weight: .medium)
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Kilitli")!)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let title = NSTextField(labelWithString: "Ekran kilitli")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let hint = NSTextField(labelWithString: "Devam etmek için şifreni gir.")
        hint.font = .systemFont(ofSize: 14)
        hint.textColor = .secondaryLabelColor

        passwordField.placeholderString = "Şifre"
        passwordField.setAccessibilityLabel("Geçici ekran kilidi şifresi")
        passwordField.font = .systemFont(ofSize: 20)
        passwordField.alignment = .center
        passwordField.bezelStyle = .roundedBezel
        (passwordField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        passwordField.target = self
        passwordField.action = #selector(unlock)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        passwordField.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let button = NSButton(title: "Kilidi aç", target: self, action: #selector(unlock))
        button.bezelStyle = .rounded
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .systemRed
        let footer = NSTextField(labelWithString: "Slack Wake Lock · Geçici ekran kilidi")
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor

        batteryLabel.font = .systemFont(ofSize: 14, weight: .medium)
        batteryLabel.setAccessibilityIdentifier("lockBatteryStatus")
        batteryIcon.translatesAutoresizingMaskIntoConstraints = false
        batteryIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        batteryIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let batteryRow = NSStackView(views: [batteryIcon, batteryLabel])
        batteryRow.spacing = 8
        batteryRow.alignment = .centerY

        let stack = NSStackView(views: [timeLabel, dateLabel, batteryRow, icon, title, hint, passwordField, button, errorLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(28, after: batteryRow)
        stack.setCustomSpacing(24, after: errorLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        slackStack.orientation = .vertical
        slackStack.identifier = NSUserInterfaceItemIdentifier("slackPreviewPanel")
        slackStack.alignment = .leading
        slackStack.spacing = 12
        slackStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slackStack)
        NSLayoutConstraint.activate([
            slackStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            slackStack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            slackStack.widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    func updateClock(_ date: Date) {
        timeLabel.stringValue = Fmt.hm.string(from: date)
        dateLabel.stringValue = Fmt.pretty.string(from: date)
    }

    func clearPassword() { passwordField.stringValue = "" }

    func updateBattery(_ status: BatteryStatus) {
        batteryLabel.stringValue = status.text
        batteryLabel.setAccessibilityLabel(status.text)
        batteryIcon.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)
        let color: NSColor = status.charging ? .systemGreen : (status.percentage ?? 100) <= 20 ? .systemRed : .secondaryLabelColor
        batteryLabel.textColor = color
        batteryIcon.contentTintColor = color
    }

    func updateSlack(_ previews: [SlackNotificationPreview], status: String) {
        for view in slackStack.arrangedSubviews {
            slackStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let heading = NSTextField(labelWithString: "Slack")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        slackStack.addArrangedSubview(heading)
        if previews.isEmpty {
            let label = NSTextField(wrappingLabelWithString: status)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 320
            slackStack.addArrangedSubview(label)
        }
        for preview in previews {
            let title = NSTextField(wrappingLabelWithString: preview.title)
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            title.maximumNumberOfLines = 2
            title.preferredMaxLayoutWidth = 320
            let body = NSTextField(wrappingLabelWithString: preview.body)
            body.font = .systemFont(ofSize: 13)
            body.maximumNumberOfLines = 4
            body.preferredMaxLayoutWidth = 320
            let time = NSTextField(labelWithString: Fmt.hm.string(from: preview.receivedAt))
            time.font = .systemFont(ofSize: 11)
            time.textColor = .secondaryLabelColor
            for view in [title, body, time] { slackStack.addArrangedSubview(view) }
            slackStack.setCustomSpacing(20, after: time)
        }
    }

    @objc private func unlock() {
        let password = passwordField.stringValue
        clearPassword()
        if onSubmit?(password) != true {
            errorLabel.stringValue = "Şifre yanlış. Tekrar dene."
            window?.makeFirstResponder(passwordField)
            NSSound.beep()
        }
    }
}
