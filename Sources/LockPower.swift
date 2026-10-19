import AppKit
import Darwin
import IOKit.ps

struct BatteryStatus {
    let percentage: Int?
    let charging: Bool
    let pluggedIn: Bool

    static let unavailable = BatteryStatus(percentage: nil, charging: false, pluggedIn: false)

    var text: String {
        guard let percentage else { return "Pil bilgisi alınamadı" }
        let state = charging ? "Şarj oluyor" : pluggedIn ? (percentage == 100 ? "Tam dolu" : "Prize bağlı") : "Pille çalışıyor"
        return "%\(percentage) · \(state)"
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        guard let percentage else { return "battery.0percent" }
        let level = percentage >= 90 ? 100 : percentage >= 65 ? 75 : percentage >= 40 ? 50 : percentage >= 15 ? 25 : 0
        return "battery.\(level)percent"
    }

    static func parse(_ description: [String: Any]) -> BatteryStatus? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int,
              current >= 0, maximum > 0 else { return nil }
        let percentage = Int((min(1, Double(current) / Double(maximum)) * 100).rounded())
        return BatteryStatus(percentage: percentage,
                             charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                             pluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
    }

    static func read() -> BatteryStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unavailable
        }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let status = parse(description) { return status }
        }
        return .unavailable
    }
}

/// DisplayServices, Apple Silicon'da da fiziksel arka ışığı kontrol eder.
/// API yoksa/donanım desteklemiyorsa sistem ayarlarına dokunmadan başarısız olur.
enum DisplayBrightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    private static let getter: Get? = {
        guard let library, let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: Get.self)
    }()
    private static let setter: Set? = {
        guard let library, let symbol = dlsym(library, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: Set.self)
    }()

    static func read(_ display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard let getter, getter(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    static func write(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard value.isFinite, let setter else { return false }
        return setter(display, min(1, max(0, value))) == 0
    }
}

/// Slack için üretilen sanal hareketlerden bağımsız, gerçek kullanıcı hareketsizliği.
@MainActor
final class LockDimmingController {
    private(set) var isDimmed = false
    var onChange: ((Bool) -> Void)?
    private var active = false
    private var originals: [CGDirectDisplayID: Float] = [:]
    private var changed = Set<CGDirectDisplayID>()
    private var displays = Set<CGDirectDisplayID>()
    private var lastInteraction: TimeInterval = 0
    private var timer: Timer?
    private let read: (CGDirectDisplayID) -> Float?
    private let write: (CGDirectDisplayID, Float) -> Bool
    private let uptime: () -> TimeInterval
    private let delay: TimeInterval = 5

    init(read: @escaping (CGDirectDisplayID) -> Float? = DisplayBrightness.read,
         write: @escaping (CGDirectDisplayID, Float) -> Bool = DisplayBrightness.write,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.read = read
        self.write = write
        self.uptime = uptime
    }

    func start(displays: [CGDirectDisplayID]) {
        guard !active else { return }
        active = true
        lastInteraction = uptime()
        updateDisplays(displays)
        scheduleCheck(after: delay)
    }

    func updateDisplays(_ current: [CGDirectDisplayID]) {
        displays = Set(current)
        for display in displays where originals[display] == nil {
            if let value = read(display) { originals[display] = value }
        }
        if isDimmed { dimDisplays() }
    }

    func userDidInteract() {
        guard active else { return }
        lastInteraction = uptime()
        if isDimmed {
            restore()
            isDimmed = false
            onChange?(false)
        }
        if timer == nil { scheduleCheck(after: delay) }
    }

    func handleInput(_ event: NSEvent) {
        guard !Nudger.isSyntheticInput(event) else { return }
        userDidInteract()
    }

    func checkForInactivity() {
        guard active else { return }
        let remaining = delay - (uptime() - lastInteraction)
        if remaining > 0 {
            scheduleCheck(after: remaining)
        } else if !isDimmed {
            timer?.invalidate()
            timer = nil
            dimDisplays()
            isDimmed = true
            onChange?(true)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        restore()
        active = false
        isDimmed = false
        originals.removeAll()
        changed.removeAll()
        displays.removeAll()
    }

    private func dimDisplays() {
        for display in displays {
            guard let original = originals[display] else { continue }
            // Zaten düşük bir parlaklığı yükseltme; en fazla %5'e indir.
            let value = min(original, 0.05)
            if value == original { continue }
            if write(display, value) {
                changed.insert(display)
            } else {
                Log.write("Geçici kilit: \(display) ekranının parlaklığı kısılamadı")
            }
        }
    }

    private func restore() {
        for display in changed.intersection(displays) {
            if let original = originals[display], write(display, original) {
                changed.remove(display)
            } else {
                Log.write("Geçici kilit: \(display) ekranının parlaklığı geri yüklenemedi")
            }
        }
    }

    private func scheduleCheck(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.checkForInactivity()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
