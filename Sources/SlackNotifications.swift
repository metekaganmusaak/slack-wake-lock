import AppKit
import ApplicationServices

struct SlackNotificationPreview: Equatable {
    let sourceID: String
    let title: String
    let body: String
    let receivedAt: Date

    /// The notification's app name field must match Slack exactly.
    /// Mentioning Slack in the message body does not establish its source.
    static func parse(sourceID: String, description: String, date: Date) -> SlackNotificationPreview? {
        let parts = description.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, parts[0].caseInsensitiveCompare("Slack") == .orderedSame,
              !parts[1].isEmpty else { return nil }
        return SlackNotificationPreview(sourceID: sourceID, title: String(parts[1].prefix(160)),
            body: parts.count > 2 ? String(parts[2].prefix(600)) : "", receivedAt: date)
    }

    var fingerprint: String { "\(sourceID)\u{1f}\(title)\u{1f}\(body)" }
}

/// Only Slack banners delivered to the screen; no database or session keys are read.
private enum SlackBannerReader {
    struct Scan {
        var previews: [SlackNotificationPreview] = []
        var windows = 0
        var banners = 0
    }

    static func read(pid: pid_t) -> Scan {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var remainingNodes = 250
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var result = Scan()

        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        func text(_ element: AXUIElement, _ key: String) -> String? {
            let value = attribute(element, key)
            if let string = value as? String { return string }
            return (value as? NSAttributedString)?.string
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 12, remainingNodes > 0, ProcessInfo.processInfo.systemUptime < deadline else { return }
            remainingNodes -= 1
            let subrole = text(element, kAXSubroleAttribute) ?? ""
            let banner = subrole.hasPrefix("AXNotificationCenterBanner") || subrole.hasPrefix("AXNotificationCenterAlert")
            if banner {
                result.banners += 1
                // Newer macOS versions may host all banners in a single window.
                // Check each banner's app field instead of the shared window name.
                let description = text(element, "AXAttributedDescription") ?? text(element, kAXDescriptionAttribute) ?? ""
                let sourceID = text(element, kAXIdentifierAttribute) ?? String(CFHash(element))
                if let preview = SlackNotificationPreview.parse(sourceID: sourceID,
                                                                description: description, date: Date()) {
                    result.previews.append(preview)
                    if !subrole.hasSuffix("Stack") { return }
                }
            }
            var children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if children.isEmpty { children = attribute(element, "AXOrderedChildren") as? [AXUIElement] ?? [] }
            for child in children { visit(child, depth: depth + 1) }
        }
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        result.windows = windows.count
        for window in windows { visit(window, depth: 0) }
        return result
    }
}

/// Previews and deduplication state stay in memory and are cleared on unlock.
@MainActor
final class SlackNotificationMonitor {
    var onUpdate: (([SlackNotificationPreview], String) -> Void)?
    var onNewNotification: (() -> Void)?
    private(set) var previews: [SlackNotificationPreview] = []
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private var active = false
    private var seeded = false
    private var timer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var generation = 0
    private var scanning = false
    private var lastDiagnostic = ""
    private let queue = DispatchQueue(label: "local.wakelock.slack-banners", qos: .utility)

    func start() {
        guard !active else { return }
        active = true
        generation += 1
        seeded = false
        lastDiagnostic = ""
        scan()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        active = false
        generation += 1
        timer?.invalidate()
        timer = nil
        removeObserver()
        previews.removeAll()
        seen.removeAll()
        seenOrder.removeAll()
        seeded = false
    }

    @discardableResult
    func consume(_ snapshots: [SlackNotificationPreview], initial: Bool = false) -> Int {
        guard active else { return 0 }
        var newCount = 0
        for preview in snapshots.reversed() {
            guard seen.insert(preview.fingerprint).inserted else { continue }
            seenOrder.append(preview.fingerprint)
            if !initial {
                previews.insert(preview, at: 0)
                newCount += 1
            }
        }
        if seenOrder.count > 500 {
            let excess = seenOrder.count - 500
            for key in seenOrder.prefix(excess) { seen.remove(key) }
            seenOrder.removeFirst(excess)
        }
        previews = Array(previews.prefix(3))
        onUpdate?(previews, "Only Slack notifications received during this lock")
        if newCount > 0 { onNewNotification?() }
        return newCount
    }

    private func scan() {
        guard active, !scanning else { return }
        guard AXIsProcessTrusted() else {
            diagnostic("Accessibility permission is missing")
            onUpdate?(previews, "Accessibility permission is required for Slack previews")
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            diagnostic("Notification Center process was not found")
            onUpdate?(previews, "Waiting for the macOS notification interface")
            return
        }
        attachObserver(to: app.processIdentifier)
        scanning = true
        let currentGeneration = generation
        let pid = app.processIdentifier
        queue.async { [weak self] in
            let scan = SlackBannerReader.read(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                guard self.active, self.generation == currentGeneration else { return }
                self.diagnostic("windows: \(scan.windows), banners: \(scan.banners), Slack: \(scan.previews.count)")
                let received = self.consume(scan.previews, initial: !self.seeded)
                if received > 0 { Log.write("Temporary lock: new Slack notifications received (count: \(received))") }
                self.seeded = true
            }
        }
    }

    private func diagnostic(_ message: String) {
        guard lastDiagnostic != message else { return }
        lastDiagnostic = message
        Log.write("Temporary lock notification monitor: \(message)")
    }

    private func attachObserver(to pid: pid_t) {
        guard observedPID != pid else { return }
        removeObserver()
        let result = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let monitor = Unmanaged<SlackNotificationMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.scan() }
        }, &observer)
        guard result == .success, let observer else { return }
        observedPID = pid
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXLayoutChangedNotification] {
            _ = AXObserverAddNotification(observer, app, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observedPID = nil
    }
}
