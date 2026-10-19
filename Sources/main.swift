// Slack Wake Lock — scheduled idle prevention and a temporary desktop overlay.
// Slack presence depends on its own activity rules, settings, and connectivity.

import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.pwr_mgt

// MARK: - Paths and small helpers

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/Wakelock", isDirectory: true)
    static let config = support.appendingPathComponent("config.json")
    static let state = support.appendingPathComponent("state.json")
    static let prayerCache = support.appendingPathComponent("prayer-cache.json")
    static let log = home.appendingPathComponent("Library/Logs/Wakelock.log")
    static let launchAgent = home.appendingPathComponent("Library/LaunchAgents/local.wakelock.plist")
}

enum Fmt {
    private static func make(_ format: String, _ locale: String = "en_US_POSIX") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }
    static let stamp = make("yyyy-MM-dd HH:mm:ss")
    static let day = make("yyyy-MM-dd")
    static let hm = make("HH:mm")
    static let hms = make("HH:mm:ss")
    static let pretty = make("EEEE, MMMM d", "en_US_POSIX")
    static let shortDay = make("MMM d, HH:mm", "en_US_POSIX")
}

/// "08:45" -> 525 (minutes since midnight)
func parseHHmm(_ s: String) -> Int? {
    let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
    guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...24).contains(h), (0..<60).contains(m) else { return nil }
    return h * 60 + m
}

/// 525 -> "08:45"
func hm(_ minutes: Int) -> String {
    let m = max(0, minutes)
    return String(format: "%02d:%02d", m / 60, m % 60)
}

func minutesSinceMidnight(_ date: Date) -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

func durationText(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    if seconds < 3600 { return "\(seconds / 60) min \(seconds % 60) s" }
    return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
}

enum Log {
    static func write(_ message: String) {
        let line = "\(Fmt.stamp.string(from: Date()))  \(message)\n"
        let url = Paths.log
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Settings (~/Library/Application Support/Wakelock/config.json)

struct Config: Codable {
    struct Break: Codable {
        var name: String
        var start: String
        var end: String

        // Keep existing config files intact while translating the former default label.
        var displayName: String {
            name == "\u{00D6}\u{011F}le molas\u{0131}" ? "Lunch break" : name
        }
    }

    struct Friday: Codable {
        var enabled = false             // opt-in for public distribution; no API requests until enabled
        var city = "Istanbul"
        var country = "Turkey"
        var method = 13                  // 13 = Diyanet calculation method
        var minutesBeforeEzan = 15       // minutes before prayer time when the break starts
        var minutesAfterEzan = 45        // minutes after prayer time when the break ends
        var fallbackLongitude = 28.97    // longitude for offline estimates (Istanbul)
    }

    var workDays = [1, 2, 3, 4, 5]       // 1 = Monday through 7 = Sunday
    var workStart = "08:45"
    var workEnd = "18:00"
    var breaks = [Break(name: "Lunch break", start: "12:00", end: "13:00")]
    var friday = Friday()
    var holidays: [String] = []          // e.g. "2026-10-29"; inactive on these dates
    var slackAwayAfterMinutes = 10       // assumed Slack inactivity interval before becoming away
    var nudgeWhenIdleSeconds = 60        // nudge after this many seconds without real input
    var afterHoursGraceMinutes = 30      // grace period after real input outside work hours
    var keepDisplayAwakeDuringBreaks = true
    var launchSlackIfClosed = true
    var lockScreenSlackSound = true

    static var lastError: String?

    /// Fill missing fields with defaults; use defaults if the file is invalid.
    static func load() -> Config {
        let defaults = Config()
        guard let data = try? Data(contentsOf: Paths.config) else {
            defaults.save()
            return defaults
        }
        do {
            let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any] ?? [:]
            let merged = try JSONSerialization.data(withJSONObject: merge(base, user))
            let config = try JSONDecoder().decode(Config.self, from: merged)
            lastError = nil
            return config
        } catch {
            lastError = "Could not read config.json; using defaults"
            Log.write("\(lastError!): \(error)")
            return defaults
        }
    }

    private static func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (key, value) in b {
            if let av = a[key] as? [String: Any], let bv = value as? [String: Any] {
                out[key] = merge(av, bv)
            } else {
                out[key] = value
            }
        }
        return out
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Paths.config, options: .atomic)
    }
}

struct AppState: Codable {
    var pausedUntil: Date?
}

// MARK: - Friday prayer time (aladhan.com, Diyanet; monthly cache and offline estimate)

final class PrayerTimes {
    private var cache: [String: [String: String]] = [:]   // "city|country|method" -> ["2026-10-23": "12:53"]
    private var inFlight = Set<String>()
    private var failedAt: [String: Date] = [:]
    var onUpdate: (() -> Void)?

    init() {
        if let data = try? Data(contentsOf: Paths.prayerCache),
           let c = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            cache = c
        }
    }

    static func key(_ f: Config.Friday) -> String {
        "\(f.city.lowercased())|\(f.country.lowercased())|\(f.method)"
    }

    /// Prayer time in minutes since midnight. Start a download if not cached
    /// and return an estimate in the meantime.
    func dhuhr(on date: Date, _ f: Config.Friday) -> (minutes: Int, approximate: Bool) {
        if let s = cache[Self.key(f)]?[Fmt.day.string(from: date)], let m = parseHHmm(s) {
            return (m, false)
        }
        fetchMonth(of: date, f)
        return (Self.approxDhuhr(on: date, longitude: f.fallbackLongitude), true)
    }

    /// Prefetch this month and the month a week ahead to cover the next Friday.
    func prefetch(_ date: Date, _ f: Config.Friday) {
        fetchMonth(of: date, f)
        if let next = Calendar.current.date(byAdding: .day, value: 7, to: date) {
            fetchMonth(of: next, f)
        }
    }

    func store(_ days: [String: String], _ f: Config.Friday) {
        cache[Self.key(f), default: [:]].merge(days) { _, new in new }
        try? JSONEncoder().encode(cache).write(to: Paths.prayerCache, options: .atomic)
    }

    private func fetchMonth(of date: Date, _ f: Config.Friday) {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        guard let y = c.year, let m = c.month else { return }
        let key = Self.key(f)
        let prefix = String(format: "%04d-%02d-", y, m)
        if cache[key]?.keys.contains(where: { $0.hasPrefix(prefix) }) == true { return }
        let job = key + "#" + prefix
        if inFlight.contains(job) { return }
        if let t = failedAt[job], Date().timeIntervalSince(t) < 600 { return }
        inFlight.insert(job)
        Self.download(year: y, month: m, f) { [weak self] days, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(job)
                if let days, !days.isEmpty {
                    self.store(days, f)
                    Log.write("Prayer times downloaded: \(f.city) \(prefix.dropLast()) (\(days.count) days)")
                    self.onUpdate?()
                } else {
                    self.failedAt[job] = Date()
                    Log.write("Could not fetch prayer times (\(f.city) \(prefix.dropLast())): \(error ?? "invalid response"); using an estimate")
                }
            }
        }
    }

    static func download(year: Int, month: Int, _ f: Config.Friday,
                         completion: @escaping ([String: String]?, String?) -> Void) {
        var c = URLComponents(string: "https://api.aladhan.com/v1/calendarByCity/\(year)/\(month)")!
        c.queryItems = [
            URLQueryItem(name: "city", value: f.city),
            URLQueryItem(name: "country", value: f.country),
            URLQueryItem(name: "method", value: String(f.method)),
        ]
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(nil, error.localizedDescription)
            } else {
                completion(parse(data), nil)
            }
        }.resume()
    }

    /// Map each day in the response from "yyyy-MM-dd" to its Dhuhr time "HH:mm".
    static func parse(_ data: Data?) -> [String: String]? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? Int) == 200,
              let days = root["data"] as? [[String: Any]] else { return nil }
        var out: [String: String] = [:]
        for d in days {
            guard let timings = d["timings"] as? [String: Any],
                  let dhuhr = timings["Dhuhr"] as? String,               // "12:53 (+03)"
                  let date = d["date"] as? [String: Any],
                  let gregorian = date["gregorian"] as? [String: Any],
                  let ddmmyyyy = gregorian["date"] as? String else { continue }  // "23-10-2026"
            let p = ddmmyyyy.split(separator: "-")
            guard p.count == 3, parseHHmm(String(dhuhr.prefix(5))) != nil else { continue }
            out["\(p[2])-\(p[1])-\(p[0])"] = String(dhuhr.prefix(5))
        }
        return out
    }

    /// Offline estimate: solar noon (NOAA formula) plus Diyanet's ~5-minute margin.
    static func approxDhuhr(on date: Date, longitude: Double) -> Int {
        let n = Double(Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1)
        let g = 2 * Double.pi / 365 * (n - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g)
                               - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let tz = Double(TimeZone.current.secondsFromGMT(for: date)) / 60
        return Int((720 - 4 * longitude - eqTime + tz).rounded()) + 5
    }
}

// MARK: - Daily schedule

struct DayPlan {
    struct Block {
        var label: String
        var start: Int
        var end: Int
    }

    enum Phase {
        case offDay(String)                     // weekend / holiday
        case beforeWork
        case afterWork
        case working(until: Int)                // keep awake is active
        case windingDown(next: String, at: Int) // stop nudging ahead of a break or the end of work
        case onBreak(String, until: Int)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    let isWorkday: Bool
    let offReason: String
    let workStart: Int
    let workEnd: Int
    let breaks: [Block]      // merged and sorted
    let nudge: [Block]       // mouse-nudging intervals
    let ezan: Int?
    let ezanApproximate: Bool

    init(date: Date, config: Config, prayer: PrayerTimes) {
        let isoWeekday = (Calendar.current.component(.weekday, from: date) + 5) % 7 + 1
        workStart = parseHHmm(config.workStart) ?? 8 * 60 + 45
        workEnd = parseHHmm(config.workEnd) ?? 18 * 60

        if config.holidays.contains(Fmt.day.string(from: date)) {
            isWorkday = false
            offReason = "Holiday"
        } else if !config.workDays.contains(isoWeekday) {
            isWorkday = false
            offReason = "Weekend"
        } else {
            isWorkday = true
            offReason = ""
        }

        var raw: [Block] = config.breaks.compactMap { b in
            guard let s = parseHHmm(b.start), let e = parseHHmm(b.end), e > s else { return nil }
            return Block(label: b.displayName, start: s, end: e)
        }
        if isoWeekday == 5 && config.friday.enabled {
            let d = prayer.dhuhr(on: date, config.friday)
            ezan = d.minutes
            ezanApproximate = d.approximate
            raw.append(Block(label: "Friday prayer",
                             start: d.minutes - config.friday.minutesBeforeEzan,
                             end: d.minutes + config.friday.minutesAfterEzan))
        } else {
            ezan = nil
            ezanApproximate = false
        }

        // Merge overlapping breaks, such as Friday prayer and lunch.
        var merged: [Block] = []
        for b in raw.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, b.start <= last.end {
                last.end = max(last.end, b.end)
                last.label += " + " + b.label
                merged[merged.count - 1] = last
            } else {
                merged.append(b)
            }
        }
        breaks = merged

        // Subtract breaks from the work interval.
        var active: [Block] = []
        var cursor = workStart
        for b in merged where b.end > workStart && b.start < workEnd {
            if b.start > cursor { active.append(Block(label: "", start: cursor, end: b.start)) }
            cursor = max(cursor, b.end)
        }
        if cursor < workEnd { active.append(Block(label: "", start: cursor, end: workEnd)) }

        // Stop nudging one assumed Slack away interval before each segment ends.
        // This gives Slack time to become away around the scheduled boundary.
        let lead = max(0, config.slackAwayAfterMinutes)
        nudge = active.compactMap { a in
            a.end - lead > a.start ? Block(label: "", start: a.start, end: a.end - lead) : nil
        }
    }

    func phase(at m: Int) -> Phase {
        guard isWorkday else { return .offDay(offReason) }
        if m < workStart { return .beforeWork }
        if m >= workEnd { return .afterWork }
        if let b = breaks.first(where: { m >= $0.start && m < $0.end }) {
            return .onBreak(b.label, until: min(b.end, workEnd))
        }
        if let n = nudge.first(where: { m >= $0.start && m < $0.end }) {
            return .working(until: n.end)
        }
        if let next = breaks.first(where: { $0.start > m && $0.start < workEnd }) {
            return .windingDown(next: next.label, at: next.start)
        }
        return .windingDown(next: "End of workday", at: workEnd)
    }

    func lines(_ config: Config) -> [String] {
        guard isWorkday else { return ["\(offReason): Slack Wake Lock is inactive today"] }
        var items: [(Int, String)] = nudge.map { ($0.start, "🟢  \(hm($0.start))–\(hm($0.end))   keep awake") }
        for b in breaks where b.end > workStart && b.start < workEnd {
            let icon = b.label.contains("Friday") ? "🕌" : "☕️"
            items.append((b.start, "\(icon)  \(hm(b.start))–\(hm(b.end))   \(b.label)"))
        }
        var out = items.sorted { $0.0 < $1.0 }.map { $0.1 }
        if let ezan {
            out.append("🕌  Friday prayer time (\(config.friday.city)): \(hm(ezan))\(ezanApproximate ? " (estimated, waiting for internet)" : "")")
        }
        if config.afterHoursGraceMinutes > 0 {
            out.append("🌙  Outside work hours: only while you are active (+\(config.afterHoursGraceMinutes) min after your last input)")
        }
        return out
    }
}

// MARK: - Mouse nudging (refresh the system idle timer)

final class Nudger {
    static let anyInputEvent = CGEventType(rawValue: ~0)!
    static let syntheticEventTag: Int64 = 0x57414B454C4F434B

    static func isSyntheticInput(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticEventTag
    }

    private(set) var lastNudgeAt: Date?
    private(set) var lastNudgeWorked: Bool?
    private var wiggle = false
    private var userActivityID: IOPMAssertionID = 0

    /// Seconds since the last keyboard or mouse input.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
    }

    /// AXIsProcessTrusted updates immediately; event-posting access may stay stale until relaunch.
    static var hasPermission: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    static func requestPermission() { _ = CGRequestPostEventAccess() }

    func nudge() {
        // Declare local user activity to power management, also keeping the display awake.
        IOPMAssertionDeclareUserActivity("Slack Wake Lock" as CFString, kIOPMUserActiveLocal, &userActivityID)

        // Move the pointer to its existing position to attempt an idle reset.
        if Self.hasPermission, let position = CGEvent(source: nil)?.location {
            let source = CGEventSource(stateID: .hidSystemState)
            if wiggle { post(CGPoint(x: position.x + 1, y: position.y), source) }
            post(position, source)
        }
        lastNudgeAt = Date()

        // If that did not reset idle time, use a one-pixel round trip next time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let worked = Self.idleSeconds < 2
            if !worked && !self.wiggle && Self.hasPermission {
                self.wiggle = true
                Log.write("Stationary movement did not reset idle time; switching to a 1-pixel round trip")
            }
            if worked != self.lastNudgeWorked {
                Log.write(worked ? "Mouse nudging is working (idle time reset)"
                                 : "WARNING: Mouse nudging did not reset idle time (Accessibility permission?)")
            }
            self.lastNudgeWorked = worked
        }
    }

    private func post(_ point: CGPoint, _ source: CGEventSource?) {
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        event?.post(tap: .cghidEventTap)
    }
}

// MARK: - Preventing system and display sleep

final class PowerAssertions {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0

    func set(system: Bool, display: Bool) {
        Self.toggle(&systemID, system, "PreventUserIdleSystemSleep", "Slack Wake Lock: keep Mac awake during work hours")
        Self.toggle(&displayID, display, "PreventUserIdleDisplaySleep", "Slack Wake Lock: keep display on during work hours")
    }

    private static func toggle(_ id: inout IOPMAssertionID, _ on: Bool, _ type: String, _ name: String) {
        if on, id == 0 {
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

// MARK: - Slack and launch at login

enum Slack {
    static let bundleID = "com.tinyspeck.slackmacgap"
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var isInstalled: Bool { appURL != nil }
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    static func launchInBackground() {
        guard let url = appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            Log.write(error.map { "Could not launch Slack: \($0.localizedDescription)" } ?? "Slack was closed; opened in the background")
        }
    }
}

enum LoginItem {
    static let label = "local.wakelock"
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: Paths.launchAgent.path) }

    static func enable() {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // restart after a crash, but not after a normal quit
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? label],
        ]
        try? FileManager.default.createDirectory(at: Paths.launchAgent.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: Paths.launchAgent, options: .atomic)
        }
    }

    static func disable() { try? FileManager.default.removeItem(at: Paths.launchAgent) }
}

// MARK: - Application

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var config = Config()
    private var configModified: Date?
    private let prayer = PrayerTimes()
    private let power = PowerAssertions()
    private let nudger = Nudger()
    private let temporaryLock = TemporaryLockController()
    private var pausedUntil: Date?
    private var lastRealActivity = Date()
    private var wasWorking = false
    private var lastStatus = ""
    private var lastWarnings = ""
    private var hadPermissionAtLaunch = false
    private var currentSymbol = ""
    private var activity: NSObjectProtocol?
    private var timer: Timer?

    private struct Snapshot {
        let plan: DayPlan
        let phase: DayPlan.Phase
        let overtime: Bool
        let paused: Bool
        let temporarilyLocked: Bool
        var nudging: Bool { temporarilyLocked || (!paused && (phase.isWorking || overtime)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        config = Config.load()
        configModified = configFileDate()
        loadState()
        lastRealActivity = Date().addingTimeInterval(-Nudger.idleSeconds)

        // Prevent App Nap from throttling the timer.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Slack Wake Lock timer")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        prayer.onUpdate = { [weak self] in self?.tick() }
        temporaryLock.onUnlock = { [weak self] in
            Log.write("Temporary lock dismissed; returning to the normal schedule")
            self?.tick()
        }
        if config.friday.enabled { prayer.prefetch(Date(), config.friday) }

        hadPermissionAtLaunch = Nudger.hasPermission
        if !hadPermissionAtLaunch { Nudger.requestPermission() }

        let t = Timer(timeInterval: 15, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(tick), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(tick), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(tick), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        Log.write("Slack Wake Lock started")
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        temporaryLock.tearDown()
        power.set(system: false, display: false)
    }

    // MARK: Main loop (every 15 seconds)

    @objc private func tick() {
        reloadConfigIfChanged()
        let now = Date()

        // Relaunch after a new permission grant so event posting picks it up.
        if !hadPermissionAtLaunch && Nudger.hasPermission && !temporaryLock.isLocked {
            relaunch()
            return
        }

        let warnings = [
            Nudger.hasPermission ? nil : "Accessibility permission is missing",
            Slack.isInstalled ? nil : "Slack desktop app was not found",
            Config.lastError,
        ].compactMap { $0 }.joined(separator: ", ")
        if warnings != lastWarnings {
            Log.write(warnings.isEmpty ? "No warnings; everything is ready" : "WARNING: \(warnings)")
            lastWarnings = warnings
        }

        // Distinguish real user activity from our synthetic movements.
        let idle = Nudger.idleSeconds
        let lastInput = now.addingTimeInterval(-idle)
        if lastInput.timeIntervalSince(nudger.lastNudgeAt ?? .distantPast) > 1.5, lastInput > lastRealActivity {
            lastRealActivity = lastInput
        }

        if let p = pausedUntil, p <= now {
            pausedUntil = nil
            saveState()
            Log.write("Pause expired; resuming")
        }

        let s = snapshot(now)
        let inWorkHours = s.plan.isWorkday && (s.plan.workStart..<s.plan.workEnd).contains(minutesSinceMidnight(now))
        power.set(system: s.temporarilyLocked || (!s.paused && (inWorkHours || s.overtime)),
                  display: s.temporarilyLocked || (!s.paused && (s.nudging || (inWorkHours && config.keepDisplayAwakeDuringBreaks))))

        let working = s.temporarilyLocked || (!s.paused && s.phase.isWorking)
        if working && !wasWorking && config.launchSlackIfClosed && Slack.isInstalled && !Slack.isRunning {
            Slack.launchInBackground()
        }
        wasWorking = working

        if s.nudging && idle >= Double(max(10, config.nudgeWhenIdleSeconds)) {
            nudger.nudge()
        }

        let status = statusText(s)
        if status != lastStatus {
            Log.write("Status: \(status)")
            lastStatus = status
        }
        updateIcon(s)
        if config.friday.enabled { prayer.prefetch(now, config.friday) }
    }

    private func snapshot(_ now: Date) -> Snapshot {
        let plan = DayPlan(date: now, config: config, prayer: prayer)
        let phase = plan.phase(at: minutesSinceMidnight(now))

        // Outside work hours on a workday, allow a grace period after real input.
        var overtime = false
        if plan.isWorkday && config.afterHoursGraceMinutes > 0 {
            let dayStart = Calendar.current.startOfDay(for: now)
            var segmentStart: Date?
            if case .beforeWork = phase { segmentStart = dayStart }
            if case .afterWork = phase { segmentStart = dayStart.addingTimeInterval(Double(plan.workEnd) * 60) }
            if let segmentStart {
                overtime = lastRealActivity >= segmentStart
                    && now.timeIntervalSince(lastRealActivity) <= Double(config.afterHoursGraceMinutes) * 60
            }
        }
        return Snapshot(plan: plan, phase: phase, overtime: overtime, paused: pausedUntil != nil,
                        temporarilyLocked: temporaryLock.isLocked)
    }

    private func statusText(_ s: Snapshot) -> String {
        if s.temporarilyLocked { return "🔒  Temporary screen lock is on; keep awake is active" }
        if let p = pausedUntil {
            if p == .distantFuture { return "⏸  Paused until you resume" }
            let when = Calendar.current.isDateInToday(p) ? Fmt.hm.string(from: p)
                     : Calendar.current.isDateInTomorrow(p) ? "tomorrow at \(Fmt.hm.string(from: p))"
                     : Fmt.shortDay.string(from: p)
            return "⏸  Paused until \(when)"
        }
        switch s.phase {
        case .working(let until):
            return "🟢  Keeping awake until \(hm(until))"
        case .windingDown(let next, let at):
            return "⏳  \(hm(at)) \(next): allowing Slack to become away"
        case .onBreak(let label, let until):
            return "\(label.contains("Friday") ? "🕌" : "☕️")  \(label) until \(hm(until)): mouse nudging is off"
        case .beforeWork:
            return s.overtime ? "⚡️  Before work: keeping awake while you are active"
                              : "🌙  Before work (starts at \(hm(s.plan.workStart)))"
        case .afterWork:
            return s.overtime ? "⚡️  After work: keeping awake while you are active"
                              : "🌙  Workday ended"
        case .offDay(let reason):
            return "🌙  \(reason)"
        }
    }

    private func updateIcon(_ s: Snapshot) {
        var symbol: String
        if s.temporarilyLocked {
            symbol = "lock.fill"
        } else if s.paused {
            symbol = "pause.circle"
        } else {
            switch s.phase {
            case .working: symbol = "bolt.fill"
            case .windingDown: symbol = "hourglass"
            case .onBreak(let label, _): symbol = label.contains("Friday") ? "moon.stars" : "cup.and.saucer"
            case .beforeWork, .afterWork, .offDay: symbol = s.overtime ? "bolt" : "moon.zzz"
            }
        }
        if !Nudger.hasPermission || !Slack.isInstalled || Config.lastError != nil {
            symbol = "exclamationmark.triangle"
        }
        guard symbol != currentSymbol, let button = statusItem.button else { return }
        currentSymbol = symbol
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Slack Wake Lock") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "WL"
        }
        button.toolTip = "Slack Wake Lock"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let s = snapshot(now)

        addInfo(menu, statusText(s), bold: true)
        var idleLine = "Idle: \(durationText(Int(Nudger.idleSeconds)))"
        if let t = nudger.lastNudgeAt { idleLine += "  ·  last nudge \(Fmt.hms.string(from: t))" }
        addInfo(menu, idleLine)

        menu.addItem(.separator())
        addAction(menu, "🔒  Open temporary screen lock", #selector(lockScreen))
        let slackSound = addAction(menu, "Extra Slack alert sound during temporary lock", #selector(toggleLockSlackSound))
        slackSound.state = config.lockScreenSlackSound ? .on : .off
        addAction(menu, "Test Slack lock notification and sound", #selector(testLockSlackNotification))

        var warnings = false
        func warningSeparator() {
            if !warnings { menu.addItem(.separator()); warnings = true }
        }
        if !Nudger.hasPermission {
            warningSeparator()
            addAction(menu, "⚠️  Accessibility permission required: enable Slack Wake Lock…", #selector(openAccessibility))
        }
        if !Slack.isInstalled {
            warningSeparator()
            addAction(menu, "⚠️  Slack desktop app is not installed: download…", #selector(openSlackDownload))
        } else if !Slack.isRunning {
            warningSeparator()
            addAction(menu, "ℹ️  Slack is closed: open", #selector(launchSlack))
        }
        if nudger.lastNudgeWorked == false {
            warningSeparator()
            addInfo(menu, "⚠️  The last nudge did not reset idle time")
        }
        if let error = Config.lastError {
            warningSeparator()
            addInfo(menu, "⚠️  \(error)")
        }

        menu.addItem(.separator())
        addInfo(menu, "Today: \(Fmt.pretty.string(from: now))", bold: true)
        for line in s.plan.lines(config) { addInfo(menu, line) }
        if s.plan.isWorkday && config.slackAwayAfterMinutes > 0 {
            addInfo(menu, "Note: Slack may mark you away after \(config.slackAwayAfterMinutes) min of inactivity;")
            addInfo(menu, "nudging stops \(config.slackAwayAfterMinutes) min before each break.")
        }

        menu.addItem(.separator())
        if pausedUntil != nil {
            addAction(menu, "▶︎  Resume", #selector(resume))
        } else {
            let sub = NSMenu()
            sub.autoenablesItems = false
            addAction(sub, "1 hour", #selector(pauseHour))
            addAction(sub, "For today (resume tomorrow)", #selector(pauseToday))
            addAction(sub, "Until I resume", #selector(pauseForever))
            let item = NSMenuItem(title: "⏸  Pause", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addAction(menu, "Friday prayer city: \(config.friday.city)…", #selector(changeCity))
        addAction(menu, "Edit settings (config.json)…", #selector(openConfig))
        addAction(menu, "Show log", #selector(openLog))
        let login = addAction(menu, "Launch at login", #selector(toggleLoginItem))
        login.state = LoginItem.isEnabled ? .on : .off

        menu.addItem(.separator())
        addAction(menu, "Quit Slack Wake Lock", #selector(quit), key: "q")
    }

    private func addInfo(_ menu: NSMenu, _ title: String, bold: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: Menu actions

    @objc private func lockScreen() {
        // Show the covering windows after the menu closes.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.temporaryLock.isLocked else { return }
            self.temporaryLock.playSlackSound = self.config.lockScreenSlackSound
            self.temporaryLock.lock()
            guard self.temporaryLock.isLocked else { return }
            Log.write("Temporary screen lock enabled; keep awake remains active until unlocked")
            self.tick()
        }
    }

    @objc private func toggleLockSlackSound() {
        config.lockScreenSlackSound.toggle()
        config.save()
        configModified = configFileDate()
        temporaryLock.playSlackSound = config.lockScreenSlackSound
    }

    @objc private func testLockSlackNotification() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.temporaryLock.playSlackSound = self.config.lockScreenSlackSound
            self.temporaryLock.showSlackTest()
            self.tick()
        }
    }

    @objc private func pauseHour() { setPause(Date().addingTimeInterval(3600)) }

    @objc private func pauseToday() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        setPause(tomorrow)
    }

    @objc private func pauseForever() { setPause(.distantFuture) }

    @objc private func resume() { setPause(nil) }

    private func setPause(_ until: Date?) {
        pausedUntil = until
        saveState()
        Log.write(until == nil ? "Resumed" : "Paused")
        tick()
    }

    @objc private func changeCity() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Which city should be used for Friday prayer times?"
        alert.informativeText = "Enter a city name using Latin characters (e.g. Istanbul, Ankara, Izmir, Bursa). Times are fetched from aladhan.com using the Diyanet calculation method. Country and method can be changed in config.json."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = config.friday.city
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let city = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty, city != config.friday.city else { return }
        config.friday.city = city
        config.save()
        configModified = configFileDate()
        Log.write("Friday prayer city changed: \(city)")
        if config.friday.enabled { prayer.prefetch(Date(), config.friday) }
        tick()
    }

    @objc private func openConfig() {
        let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
        if let vscode {
            NSWorkspace.shared.open([Paths.config], withApplicationAt: vscode, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(Paths.config)
        }
    }

    @objc private func openLog() {
        Log.write("Log opened")
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([Paths.log], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openAccessibility() {
        Nudger.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSlackDownload() {
        if let url = URL(string: "https://slack.com/downloads/mac") { NSWorkspace.shared.open(url) }
    }

    @objc private func launchSlack() { Slack.launchInBackground() }

    @objc private func toggleLoginItem() {
        if LoginItem.isEnabled {
            LoginItem.disable()
            Log.write("Launch at login disabled")
        } else {
            LoginItem.enable()
            Log.write("Launch at login enabled")
        }
    }

    @objc private func quit() {
        Log.write("Slack Wake Lock stopped")
        NSApp.terminate(nil)
    }

    private func relaunch() {
        Log.write("Accessibility permission granted; restarting Slack Wake Lock")
        power.set(system: false, display: false)
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LoginItem.label {
            exit(75)   // running under launchd: a nonzero exit triggers a restart
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? shell.run()
        exit(0)
    }

    // MARK: Persistent state

    private func configFileDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.config.path))?[.modificationDate] as? Date
    }

    private func reloadConfigIfChanged() {
        let modified = configFileDate()
        guard modified != configModified else { return }
        configModified = modified
        config = Config.load()
        if Config.lastError == nil { Log.write("Settings reloaded") }
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: Paths.state),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else { return }
        pausedUntil = state.pausedUntil
    }

    private func saveState() {
        try? JSONEncoder().encode(AppState(pausedUntil: pausedUntil)).write(to: Paths.state, options: .atomic)
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

// MARK: - Command line: print the schedule (Wakelock --plan [yyyy-MM-dd])

func printPlan(_ dateArgument: String?) {
    let date = dateArgument.flatMap { Fmt.day.date(from: $0) } ?? Date()
    let config = Config.load()
    let prayer = PrayerTimes()
    if Calendar.current.component(.weekday, from: date) == 6 && config.friday.enabled {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        let done = DispatchSemaphore(value: 0)
        var fetched: [String: String]?
        PrayerTimes.download(year: c.year!, month: c.month!, config.friday) { days, error in
            fetched = days
            if let error { print("(could not download prayer time: \(error))") }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 25)
        if let fetched { prayer.store(fetched, config.friday) }
    }
    let plan = DayPlan(date: date, config: config, prayer: prayer)
    print("Plan: \(Fmt.pretty.string(from: date))")
    for line in plan.lines(config) { print("  " + line) }
    print("\nTimeline (5-minute intervals, changes only):")
    var previous = ""
    for m in stride(from: 0, to: 24 * 60, by: 5) {
        let text: String
        switch plan.phase(at: m) {
        case .working(let until): text = "NUDGE (until \(hm(until)))"
        case .windingDown(let next, let at): text = "wait: \(hm(at)) \(next)"
        case .onBreak(let label, let until): text = "BREAK: \(label) (until \(hm(until)))"
        case .beforeWork: text = "before work"
        case .afterWork: text = "after work"
        case .offDay(let reason): text = reason
        }
        if text != previous {
            print("  \(hm(m))  \(text)")
            previous = text
        }
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print("Slack Wake Lock \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
    exit(0)
}
if let i = arguments.firstIndex(of: "--plan") {
    printPlan(i + 1 < arguments.count ? arguments[i + 1] : nil)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
