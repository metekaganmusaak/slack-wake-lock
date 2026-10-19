// Slack Wake Lock — Slack masaüstü uygulamasında mesai saatlerinde "çevrimiçi" görünmeni sağlayan menü çubuğu uygulaması.
//
// Nasıl çalışır?
//   Slack masaüstü uygulaması, bilgisayarın klavye/fare için tuttuğu "boşta kalma" sayacına bakar;
//   sayaç 10 dakikayı geçince seni "uzakta" gösterir. Slack Wake Lock mesai saatlerinde, sen 1 dakikadan uzun
//   süre bilgisayara dokunmazsan fareyi olduğu yerde sanal olarak "kıpırdatır" (imleç yerinden oynamaz),
//   böylece sayaç hiç 10 dakikaya ulaşmaz. Molalarda ve mesai dışında hiçbir şey yapmaz: o saatlerde
//   bilgisayarı gerçekten kullanıyorsan Slack seni zaten çevrimiçi gösterir, kullanmıyorsan uzakta.

import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.pwr_mgt

// MARK: - Dosya yolları ve küçük yardımcılar

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
    static let pretty = make("d MMMM EEEE", "tr_TR")
    static let shortDay = make("d MMM HH:mm", "tr_TR")
}

/// "08:45" -> 525 (gece yarısından itibaren dakika)
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
    if seconds < 60 { return "\(seconds) sn" }
    if seconds < 3600 { return "\(seconds / 60) dk \(seconds % 60) sn" }
    return "\(seconds / 3600) sa \((seconds % 3600) / 60) dk"
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

// MARK: - Ayarlar (~/Library/Application Support/Wakelock/config.json)

struct Config: Codable {
    struct Break: Codable {
        var name: String
        var start: String
        var end: String
    }

    struct Friday: Codable {
        var enabled = false             // genel dağıtımda isteğe bağlı; açılmadan API isteği yapılmaz
        var city = "Istanbul"
        var country = "Turkey"
        var method = 13                  // 13 = Diyanet İşleri Başkanlığı hesaplama yöntemi
        var minutesBeforeEzan = 15       // camiye gitmek için ezandan bu kadar önce mola başlar
        var minutesAfterEzan = 45        // namaz bitip dönünce, ezandan bu kadar sonra mola biter
        var fallbackLongitude = 28.97    // internet yoksa yaklaşık hesap için boylam (İstanbul)
    }

    var workDays = [1, 2, 3, 4, 5]       // 1 = Pazartesi … 7 = Pazar
    var workStart = "08:45"
    var workEnd = "18:00"
    var breaks = [Break(name: "Öğle molası", start: "12:00", end: "13:00")]
    var friday = Friday()
    var holidays: [String] = []          // "2026-10-29" gibi; bu günler hiç çalışmaz
    var slackAwayAfterMinutes = 10       // Slack'in seni uzakta göstermesi için gereken hareketsizlik
    var nudgeWhenIdleSeconds = 60        // bu kadar süre dokunmazsan fare kıpırdatılır
    var afterHoursGraceMinutes = 30      // mesai dışında çalışıyorsan, son hareketinden sonra bu kadar çevrimiçi tut
    var keepDisplayAwakeDuringBreaks = true
    var launchSlackIfClosed = true
    var lockScreenSlackSound = true

    static var lastError: String?

    /// Dosyada olmayan alanlar varsayılan değerleriyle tamamlanır; bozuk dosyada varsayılanlar kullanılır.
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
            lastError = "config.json okunamadı, varsayılanlar kullanılıyor"
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

// MARK: - Cuma ezan vakti (aladhan.com, Diyanet yöntemi; aylık önbellek + çevrimdışı yaklaşık hesap)

final class PrayerTimes {
    private var cache: [String: [String: String]] = [:]   // "şehir|ülke|yöntem" -> ["2026-10-23": "12:53"]
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

    /// Verilen günün öğle ezanı (gece yarısından itibaren dakika). Önbellekte yoksa indirmeyi başlatır
    /// ve o sırada yaklaşık hesabı döndürür.
    func dhuhr(on date: Date, _ f: Config.Friday) -> (minutes: Int, approximate: Bool) {
        if let s = cache[Self.key(f)]?[Fmt.day.string(from: date)], let m = parseHHmm(s) {
            return (m, false)
        }
        fetchMonth(of: date, f)
        return (Self.approxDhuhr(on: date, longitude: f.fallbackLongitude), true)
    }

    /// Bu ayı ve bir hafta sonrasının ayını önceden indir (bir sonraki Cuma her zaman hazır olsun).
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
                    Log.write("Namaz vakitleri indirildi: \(f.city) \(prefix.dropLast()) (\(days.count) gün)")
                    self.onUpdate?()
                } else {
                    self.failedAt[job] = Date()
                    Log.write("Namaz vakitleri alınamadı (\(f.city) \(prefix.dropLast())): \(error ?? "geçersiz yanıt"); yaklaşık hesap kullanılıyor")
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

    /// Yanıttaki her gün için "yyyy-MM-dd" -> "HH:mm" (Dhuhr = öğle).
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

    /// İnternet yoksa: güneşin tam tepe noktası (NOAA formülü) + Diyanet'in ~5 dk temkini.
    static func approxDhuhr(on date: Date, longitude: Double) -> Int {
        let n = Double(Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1)
        let g = 2 * Double.pi / 365 * (n - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g)
                               - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let tz = Double(TimeZone.current.secondsFromGMT(for: date)) / 60
        return Int((720 - 4 * longitude - eqTime + tz).rounded()) + 5
    }
}

// MARK: - Günlük plan

struct DayPlan {
    struct Block {
        var label: String
        var start: Int
        var end: Int
    }

    enum Phase {
        case offDay(String)                     // hafta sonu / tatil
        case beforeWork
        case afterWork
        case working(until: Int)                // aktif tutuluyor
        case windingDown(next: String, at: Int) // mola/mesai bitişi yaklaşıyor, Slack'in kendiliğinden uzakta'ya geçmesi bekleniyor
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
    let breaks: [Block]      // birleştirilmiş, sıralı
    let nudge: [Block]       // fare kıpırdatılan aralıklar
    let ezan: Int?
    let ezanApproximate: Bool

    init(date: Date, config: Config, prayer: PrayerTimes) {
        let isoWeekday = (Calendar.current.component(.weekday, from: date) + 5) % 7 + 1
        workStart = parseHHmm(config.workStart) ?? 8 * 60 + 45
        workEnd = parseHHmm(config.workEnd) ?? 18 * 60

        if config.holidays.contains(Fmt.day.string(from: date)) {
            isWorkday = false
            offReason = "Tatil günü"
        } else if !config.workDays.contains(isoWeekday) {
            isWorkday = false
            offReason = "Hafta sonu"
        } else {
            isWorkday = true
            offReason = ""
        }

        var raw: [Block] = config.breaks.compactMap { b in
            guard let s = parseHHmm(b.start), let e = parseHHmm(b.end), e > s else { return nil }
            return Block(label: b.name, start: s, end: e)
        }
        if isoWeekday == 5 && config.friday.enabled {
            let d = prayer.dhuhr(on: date, config.friday)
            ezan = d.minutes
            ezanApproximate = d.approximate
            raw.append(Block(label: "Cuma namazı",
                             start: d.minutes - config.friday.minutesBeforeEzan,
                             end: d.minutes + config.friday.minutesAfterEzan))
        } else {
            ezan = nil
            ezanApproximate = false
        }

        // Çakışan molaları birleştir (ör. kışın Cuma namazı öğle molasının içine düşer)
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

        // Mesai aralığından molaları çıkar
        var active: [Block] = []
        var cursor = workStart
        for b in merged where b.end > workStart && b.start < workEnd {
            if b.start > cursor { active.append(Block(label: "", start: cursor, end: b.start)) }
            cursor = max(cursor, b.end)
        }
        if cursor < workEnd { active.append(Block(label: "", start: cursor, end: workEnd)) }

        // Kıpırdatmayı her aralığın sonundan "Slack uzakta süresi" kadar önce bırak:
        // böylece 12:00'de (ya da 18:00'de) Slack seni tam vaktinde uzakta gösterir.
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
        return .windingDown(next: "Mesai bitişi", at: workEnd)
    }

    func lines(_ config: Config) -> [String] {
        guard isWorkday else { return ["\(offReason): Slack Wake Lock bugün hiçbir şey yapmaz"] }
        var items: [(Int, String)] = nudge.map { ($0.start, "🟢  \(hm($0.start))–\(hm($0.end))   çevrimiçi tutulur") }
        for b in breaks where b.end > workStart && b.start < workEnd {
            let icon = b.label.contains("Cuma") ? "🕌" : "☕️"
            items.append((b.start, "\(icon)  \(hm(b.start))–\(hm(b.end))   \(b.label)"))
        }
        var out = items.sorted { $0.0 < $1.0 }.map { $0.1 }
        if let ezan {
            out.append("🕌  Cuma ezanı (\(config.friday.city)): \(hm(ezan))\(ezanApproximate ? " (yaklaşık, internet bekleniyor)" : "")")
        }
        if config.afterHoursGraceMinutes > 0 {
            out.append("🌙  Mesai dışında: sadece sen çalışıyorsan (son hareketinden +\(config.afterHoursGraceMinutes) dk)")
        }
        return out
    }
}

// MARK: - Fare kıpırdatma (Slack'in baktığı "boşta kalma" sayacını sıfırlar)

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

    /// Son klavye/fare hareketinden bu yana geçen saniye (Slack/Electron da tam olarak buna bakar).
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
    }

    /// AXIsProcessTrusted izin verilince hemen güncellenir; CGPreflightPostEventAccess ise uygulama yeniden başlayana kadar eski cevabı verebilir.
    static var hasPermission: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    static func requestPermission() { _ = CGRequestPostEventAccess() }

    func nudge() {
        // Güç yönetimine "kullanıcı aktif" bildir (ekranı da uyanık tutar)
        IOPMAssertionDeclareUserActivity("Slack Wake Lock" as CFString, kIOPMUserActiveLocal, &userActivityID)

        // Fareyi olduğu yere "taşı": imleç yerinden oynamaz ama sistem bunu gerçek hareket sayar
        if Self.hasPermission, let position = CGEvent(source: nil)?.location {
            let source = CGEventSource(stateID: .hidSystemState)
            if wiggle { post(CGPoint(x: position.x + 1, y: position.y), source) }
            post(position, source)
        }
        lastNudgeAt = Date()

        // İşe yaradı mı? Yaramadıysa bir dahakine 1 piksel gidip geri gel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let worked = Self.idleSeconds < 2
            if !worked && !self.wiggle && Self.hasPermission {
                self.wiggle = true
                Log.write("Yerinde hareket sayacı sıfırlamadı; 1 piksel gidip gelmeye geçiliyor")
            }
            if worked != self.lastNudgeWorked {
                Log.write(worked ? "Kıpırdatma çalışıyor (boşta sayacı sıfırlandı)"
                                 : "UYARI: Kıpırdatma boşta sayacını sıfırlamadı (Erişilebilirlik izni?)")
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

// MARK: - Uyku / ekran kapanmasını engelleme

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

// MARK: - Slack ve otomatik başlatma

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
            Log.write(error.map { "Slack başlatılamadı: \($0.localizedDescription)" } ?? "Slack kapalıydı, arka planda açıldı")
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
            "KeepAlive": ["SuccessfulExit": false],   // çökerse yeniden başlat, "Çık" dersen başlatma
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

// MARK: - Uygulama

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

        // App Nap zamanlayıcıyı yavaşlatmasın
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Slack Wake Lock zamanlayıcısı")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        prayer.onUpdate = { [weak self] in self?.tick() }
        temporaryLock.onUnlock = { [weak self] in
            Log.write("Geçici ekran kilidi açıldı; normal plana dönülüyor")
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

        Log.write("Slack Wake Lock başladı")
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        temporaryLock.tearDown()
        power.set(system: false, display: false)
    }

    // MARK: Ana döngü (15 saniyede bir)

    @objc private func tick() {
        reloadConfigIfChanged()
        let now = Date()

        // İzin uygulama çalışırken verildiyse, fare olaylarının kesin çalışması için kendini yeniden başlat
        if !hadPermissionAtLaunch && Nudger.hasPermission && !temporaryLock.isLocked {
            relaunch()
            return
        }

        let warnings = [
            Nudger.hasPermission ? nil : "Erişilebilirlik izni yok",
            Slack.isInstalled ? nil : "Slack masaüstü uygulaması bulunamadı",
            Config.lastError,
        ].compactMap { $0 }.joined(separator: ", ")
        if warnings != lastWarnings {
            Log.write(warnings.isEmpty ? "Uyarı yok, her şey hazır" : "UYARI: \(warnings)")
            lastWarnings = warnings
        }

        // Gerçek kullanıcı hareketini bizim sanal hareketlerimizden ayır
        let idle = Nudger.idleSeconds
        let lastInput = now.addingTimeInterval(-idle)
        if lastInput.timeIntervalSince(nudger.lastNudgeAt ?? .distantPast) > 1.5, lastInput > lastRealActivity {
            lastRealActivity = lastInput
        }

        if let p = pausedUntil, p <= now {
            pausedUntil = nil
            saveState()
            Log.write("Duraklatma süresi doldu, devam ediliyor")
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
            Log.write("Durum: \(status)")
            lastStatus = status
        }
        updateIcon(s)
        if config.friday.enabled { prayer.prefetch(now, config.friday) }
    }

    private func snapshot(_ now: Date) -> Snapshot {
        let plan = DayPlan(date: now, config: config, prayer: prayer)
        let phase = plan.phase(at: minutesSinceMidnight(now))

        // Mesai dışı (iş günü): sen gerçekten bilgisayardaysan, son hareketinden sonra bir süre daha çevrimiçi tut
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
        if s.temporarilyLocked { return "🔒  Geçici ekran kilidi açık; çevrimiçi tutma etkin" }
        if let p = pausedUntil {
            if p == .distantFuture { return "⏸  Duraklatıldı (sen devam ettirene kadar)" }
            let when = Calendar.current.isDateInToday(p) ? Fmt.hm.string(from: p)
                     : Calendar.current.isDateInTomorrow(p) ? "yarın \(Fmt.hm.string(from: p))"
                     : Fmt.shortDay.string(from: p)
            return "⏸  Duraklatıldı (bitiş: \(when))"
        }
        switch s.phase {
        case .working(let until):
            return "🟢  Çevrimiçi tutuluyor (bitiş \(hm(until)))"
        case .windingDown(let next, let at):
            return "⏳  \(hm(at)) \(next): Slack seni birazdan kendiliğinden uzakta gösterecek"
        case .onBreak(let label, let until):
            return "\(label.contains("Cuma") ? "🕌" : "☕️")  \(label) (bitiş \(hm(until))): dokunulmuyor"
        case .beforeWork:
            return s.overtime ? "⚡️  Mesai öncesi, çalıştığın için çevrimiçi tutuluyor"
                              : "🌙  Mesai öncesi (başlangıç \(hm(s.plan.workStart)))"
        case .afterWork:
            return s.overtime ? "⚡️  Mesai sonrası, çalıştığın için çevrimiçi tutuluyor"
                              : "🌙  Mesai bitti"
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
            case .onBreak(let label, _): symbol = label.contains("Cuma") ? "moon.stars" : "cup.and.saucer"
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

    // MARK: Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let s = snapshot(now)

        addInfo(menu, statusText(s), bold: true)
        var idleLine = "Boşta: \(durationText(Int(Nudger.idleSeconds)))"
        if let t = nudger.lastNudgeAt { idleLine += "  ·  son kıpırdatma \(Fmt.hms.string(from: t))" }
        addInfo(menu, idleLine)

        menu.addItem(.separator())
        addAction(menu, "🔒  Geçici ekran kilidini aç", #selector(lockScreen))
        let slackSound = addAction(menu, "Geçici kilitte Slack için ek uyarı sesi", #selector(toggleLockSlackSound))
        slackSound.state = config.lockScreenSlackSound ? .on : .off
        addAction(menu, "Slack kilit bildirimi ve sesini test et", #selector(testLockSlackNotification))

        var warnings = false
        func warningSeparator() {
            if !warnings { menu.addItem(.separator()); warnings = true }
        }
        if !Nudger.hasPermission {
            warningSeparator()
            addAction(menu, "⚠️  Erişilebilirlik izni gerekli: tıkla ve Slack Wake Lock'u aç…", #selector(openAccessibility))
        }
        if !Slack.isInstalled {
            warningSeparator()
            addAction(menu, "⚠️  Slack masaüstü uygulaması yüklü değil: indir…", #selector(openSlackDownload))
        } else if !Slack.isRunning {
            warningSeparator()
            addAction(menu, "ℹ️  Slack şu an kapalı: aç", #selector(launchSlack))
        }
        if nudger.lastNudgeWorked == false {
            warningSeparator()
            addInfo(menu, "⚠️  Son kıpırdatma boşta sayacını sıfırlamadı")
        }
        if let error = Config.lastError {
            warningSeparator()
            addInfo(menu, "⚠️  \(error)")
        }

        menu.addItem(.separator())
        addInfo(menu, "Bugün: \(Fmt.pretty.string(from: now))", bold: true)
        for line in s.plan.lines(config) { addInfo(menu, line) }
        if s.plan.isWorkday && config.slackAwayAfterMinutes > 0 {
            addInfo(menu, "Not: Slack \(config.slackAwayAfterMinutes) dk hareketsizlikte uzakta gösterir;")
            addInfo(menu, "kıpırdatma bu yüzden her molanın \(config.slackAwayAfterMinutes) dk öncesinde biter.")
        }

        menu.addItem(.separator())
        if pausedUntil != nil {
            addAction(menu, "▶︎  Devam et", #selector(resume))
        } else {
            let sub = NSMenu()
            sub.autoenablesItems = false
            addAction(sub, "1 saat", #selector(pauseHour))
            addAction(sub, "Bugünlük (yarın kendiliğinden başlar)", #selector(pauseToday))
            addAction(sub, "Ben devam ettirene kadar", #selector(pauseForever))
            let item = NSMenuItem(title: "⏸  Durdur", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addAction(menu, "Cuma ezanı için şehir: \(config.friday.city)…", #selector(changeCity))
        addAction(menu, "Ayarları düzenle (config.json)…", #selector(openConfig))
        addAction(menu, "Günlüğü göster", #selector(openLog))
        let login = addAction(menu, "Mac açılınca otomatik başlat", #selector(toggleLoginItem))
        login.state = LoginItem.isEnabled ? .on : .off

        menu.addItem(.separator())
        addAction(menu, "Slack Wake Lock'tan çık", #selector(quit), key: "q")
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

    // MARK: Menü eylemleri

    @objc private func lockScreen() {
        // Menü kapandıktan sonra Dock ve menü çubuğunu gizle.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.temporaryLock.isLocked else { return }
            self.temporaryLock.playSlackSound = self.config.lockScreenSlackSound
            self.temporaryLock.lock()
            guard self.temporaryLock.isLocked else { return }
            Log.write("Geçici ekran kilidi etkin; kapatılana kadar çevrimiçi tutma açık")
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
        Log.write(until == nil ? "Devam ettirildi" : "Durduruldu")
        tick()
    }

    @objc private func changeCity() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cuma ezanı hangi şehre göre hesaplansın?"
        alert.informativeText = "Şehir adını Türkçe karakter kullanmadan yaz (ör. Istanbul, Ankara, Izmir, Bursa). Vakitler Diyanet yöntemiyle aladhan.com'dan alınır."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = config.friday.city
        alert.accessoryView = field
        alert.addButton(withTitle: "Kaydet")
        alert.addButton(withTitle: "Vazgeç")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let city = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty, city != config.friday.city else { return }
        config.friday.city = city
        config.save()
        configModified = configFileDate()
        Log.write("Cuma şehri değişti: \(city)")
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
        Log.write("Günlük açıldı")
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
            Log.write("Otomatik başlatma kapatıldı")
        } else {
            LoginItem.enable()
            Log.write("Otomatik başlatma açıldı")
        }
    }

    @objc private func quit() {
        Log.write("Slack Wake Lock kapatıldı")
        NSApp.terminate(nil)
    }

    private func relaunch() {
        Log.write("Erişilebilirlik izni verildi; Slack Wake Lock yeniden başlatılıyor")
        power.set(system: false, display: false)
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LoginItem.label {
            exit(75)   // otomatik başlatma (launchd) ile çalışıyoruz: hata koduyla çıkınca launchd yeniden açar
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? shell.run()
        exit(0)
    }

    // MARK: Kalıcı durum

    private func configFileDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.config.path))?[.modificationDate] as? Date
    }

    private func reloadConfigIfChanged() {
        let modified = configFileDate()
        guard modified != configModified else { return }
        configModified = modified
        config = Config.load()
        if Config.lastError == nil { Log.write("Ayarlar yeniden yüklendi") }
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

// MARK: - Komut satırı: planı yazdır (Wakelock --plan [yyyy-MM-dd])

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
            if let error { print("(ezan vakti indirilemedi: \(error))") }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 25)
        if let fetched { prayer.store(fetched, config.friday) }
    }
    let plan = DayPlan(date: date, config: config, prayer: prayer)
    print("Plan: \(Fmt.pretty.string(from: date))")
    for line in plan.lines(config) { print("  " + line) }
    print("\nZaman çizelgesi (5 dk aralıklarla, yalnızca değişimler):")
    var previous = ""
    for m in stride(from: 0, to: 24 * 60, by: 5) {
        let text: String
        switch plan.phase(at: m) {
        case .working(let until): text = "KIPIRDAT (\(hm(until))'a kadar)"
        case .windingDown(let next, let at): text = "bekle: \(hm(at)) \(next)"
        case .onBreak(let label, let until): text = "MOLA: \(label) (\(hm(until)))"
        case .beforeWork: text = "mesai öncesi"
        case .afterWork: text = "mesai sonrası"
        case .offDay(let reason): text = reason
        }
        if text != previous {
            print("  \(hm(m))  \(text)")
            previous = text
        }
    }
}

// MARK: - Giriş noktası

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
