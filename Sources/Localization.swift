import Foundation

struct AppLanguage: Equatable {
    let code: String
    let englishName: String
    let nativeName: String

    var title: String {
        let translated = L10n.locale.localizedString(forLanguageCode: code) ?? englishName
        let name = translated.prefix(1).uppercased(with: L10n.locale) + translated.dropFirst()
        return name.compare(nativeName, options: [.caseInsensitive, .diacriticInsensitive], locale: L10n.locale) == .orderedSame
            ? name : "\(name) — \(nativeName)"
    }
}

enum L10n {
    static let supported: [AppLanguage] = [
        AppLanguage(code: "en", englishName: "English", nativeName: "English"),
        AppLanguage(code: "tr", englishName: "Turkish", nativeName: "Türkçe"),
        AppLanguage(code: "es", englishName: "Spanish", nativeName: "Español"),
        AppLanguage(code: "it", englishName: "Italian", nativeName: "Italiano"),
        AppLanguage(code: "fr", englishName: "French", nativeName: "Français"),
        AppLanguage(code: "de", englishName: "German", nativeName: "Deutsch"),
        AppLanguage(code: "ru", englishName: "Russian", nativeName: "Русский"),
        AppLanguage(code: "uk", englishName: "Ukrainian", nativeName: "Українська"),
        AppLanguage(code: "hi", englishName: "Hindi", nativeName: "हिन्दी"),
        AppLanguage(code: "zh", englishName: "Chinese", nativeName: "中文"),
        AppLanguage(code: "ja", englishName: "Japanese", nativeName: "日本語"),
        AppLanguage(code: "ko", englishName: "Korean", nativeName: "한국어"),
        AppLanguage(code: "pt", englishName: "Portuguese", nativeName: "Português"),
        AppLanguage(code: "nb", englishName: "Norwegian", nativeName: "Norsk"),
        AppLanguage(code: "da", englishName: "Danish", nativeName: "Dansk"),
        AppLanguage(code: "sv", englishName: "Swedish", nativeName: "Svenska"),
    ]
    static let didChange = Notification.Name("SlackWakeLockLanguageDidChange")
    private(set) static var selection = "system"
    private(set) static var code = resolve("system")
    static var locale: Locale { Locale(identifier: code == "en" ? "en_US" : code) }
    static var sortedLanguages: [AppLanguage] {
        supported.sorted {
            $0.title.compare($1.title, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) == .orderedAscending
        }
    }

    static let catalog: [String: [String: String]] = {
        #if TESTING
        let url = ProcessInfo.processInfo.environment["WAKELOCK_LOCALIZATIONS"].map { URL(fileURLWithPath: $0) }
        #else
        let url = Bundle.main.url(forResource: "Localizations", withExtension: "json")
        #endif
        guard let url, let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return values
    }()

    static func normalized(_ choice: String) -> String {
        choice == "system" || supported.contains(where: { $0.code == choice }) ? choice : "system"
    }

    static func resolve(_ choice: String, preferred: [String] = Locale.preferredLanguages) -> String {
        if choice != "system", supported.contains(where: { $0.code == choice }) { return choice }
        for identifier in preferred {
            let base = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
            let candidate = ["no", "nn"].contains(base) ? "nb" : base
            if supported.contains(where: { $0.code == candidate }) { return candidate }
        }
        return "en"
    }

    static func select(_ choice: String, preferred: [String] = Locale.preferredLanguages) {
        let next = normalized(choice)
        let nextCode = resolve(next, preferred: preferred)
        guard next != selection || nextCode != code else { return }
        selection = next
        code = nextCode
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func text(_ key: String, _ arguments: Any...) -> String {
        let template = catalog[code]?[key] ?? catalog["en"]?[key] ?? key
        // Replace placeholders in one pass: message text containing {0} must stay untouched.
        let parts = template.components(separatedBy: "{")
        return parts.enumerated().map { offset, part in
            guard offset > 0 else { return part }
            guard let end = part.firstIndex(of: "}"), let index = Int(part[..<end]), arguments.indices.contains(index) else { return "{" + part }
            return String(describing: arguments[index]) + part[part.index(after: end)...]
        }.joined()
    }

    static func percent(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(value) / 100)) ?? "\(value)%"
    }
}
