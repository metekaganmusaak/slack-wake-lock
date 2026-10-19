
@MainActor
enum LocalizationTests {
    static func run() {
        let previous = L10n.selection
        defer { L10n.select(previous) }
        precondition(Config().language == "system")
        let expected = Set(["en", "tr", "es", "it", "fr", "de", "ru", "uk", "hi", "zh", "ja", "ko", "pt", "nb", "da", "sv"])
        precondition(Set(L10n.supported.map(\.code)) == expected)
        precondition(Set(L10n.catalog.keys) == expected)
        let base = L10n.catalog["en"]!
        precondition(base.count >= 72)
        for (identifier, code) in [("tr-TR", "tr"), ("en-GB", "en"), ("es-MX", "es"),
                                  ("pt-BR", "pt"), ("zh-Hant-TW", "zh"), ("nb-NO", "nb"),
                                  ("no-NO", "nb"), ("nn-NO", "nb"), ("uk_UA", "uk")] {
            precondition(L10n.resolve("system", preferred: [identifier]) == code)
        }
        precondition(L10n.resolve("system", preferred: ["ar-SA", "fr-CA"]) == "fr")
        precondition(L10n.resolve("system", preferred: ["unsupported"]) == "en")
        precondition(L10n.resolve("de", preferred: ["tr-TR"]) == "de")
        precondition(L10n.normalized("invalid") == "system")

        var config = Config()
        config.language = "ja"
        config.workStart = "09:15"
        let decoded = try! JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        precondition(decoded.language == "ja" && decoded.workStart == "09:15")
        let legacy = try! Config.decode(Data(#"{"workStart":"09:30","lockScreenSlackSound":false}"#.utf8))
        precondition(legacy.language == "system" && legacy.workStart == "09:30" && !legacy.lockScreenSlackSound)
        let restored = try! Config.decode(JSONEncoder().encode(config))
        precondition(restored.language == "ja")

        // Switching a visible lock must preserve partial PIN input and its windows.
        let controller = TemporaryLockController(dimming: LockDimmingController(read: { _ in nil }, write: { _, _ in false }))
        controller.playSlackSound = false
        controller.showSlackTest()
        defer { controller.tearDown() }
        let window = NSApp.windows.compactMap { $0 as? TemporaryLockWindow }.first { $0.isVisible }!
        window.lockView.passwordField.stringValue = "123"
        func strings(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(strings)
        }
        for language in L10n.supported {
            precondition(Set(L10n.catalog[language.code]!.keys) == Set(base.keys))
            precondition(L10n.catalog[language.code]!.values.allSatisfy { !$0.isEmpty })
            L10n.select(language.code)
            precondition(controller.isLocked && window.isVisible)
            precondition(window.lockView.passwordField.stringValue == "123")
            let labels = strings(window.lockView)
            window.lockView.layoutSubtreeIfNeeded()
            precondition(window.lockView.bounds.contains(window.lockView.convert(window.lockView.passwordField.bounds, from: window.lockView.passwordField)))
            precondition(labels.contains(L10n.text("Screen locked")))
            precondition(labels.contains("Slack Wake Lock · " + L10n.text("Local notification test")))
            precondition(window.lockView.passwordField.placeholderString == L10n.text("PIN"))
            let button = (window.lockView.subviews.compactMap { $0 as? NSStackView }.first!).arrangedSubviews.compactMap { $0 as? NSButton }.first!
            precondition(button.title == L10n.text("Unlock"))
            precondition(!Fmt.pretty.string(from: Date()).isEmpty)
            precondition(!BatteryStatus(percentage: 35, charging: true, pluggedIn: true).text.isEmpty)
            precondition(L10n.text("Paused until {0}", "{1}").contains("{1}"), "Arguments must not be recursively substituted")
            let ordered = L10n.sortedLanguages.map(\.title)
            for pair in zip(ordered, ordered.dropFirst()) {
                precondition(pair.0.compare(pair.1, options: [.caseInsensitive, .diacriticInsensitive], locale: L10n.locale) != .orderedDescending)
            }
        }
        L10n.select("tr")
        precondition(L10n.text("Unlock") == "Kilidi aç")
        precondition(BatteryStatus(percentage: 35, charging: true, pluggedIn: true).text.contains("Şarj oluyor"))
        precondition(Fmt.pretty.string(from: Fmt.stamp.date(from: "2026-10-19 10:00:00")!).contains("Pazartesi"))
        L10n.select("system", preferred: ["ja-JP"])
        precondition(L10n.code == "ja" && L10n.selection == "system")
        L10n.select("system", preferred: ["de-DE"])
        precondition(L10n.code == "de")
        AppDelegate.testLanguageMenu()
        print("PASS: 16 complete languages, system/region fallback, alphabetical order, preference coding, live lock updates, and preserved PIN")
    }
}

extension AppDelegate {
    static func testLanguageMenu() {
        for choice in ["en", "tr", "ja", "system"] {
            L10n.select(choice, preferred: ["tr-TR"])
            let delegate = AppDelegate()
            let menu = NSMenu()
            delegate.menuNeedsUpdate(menu)
            let submenu = menu.items.first { $0.title == "🌐  " + L10n.text("Language") }!.submenu!
            let items = submenu.items.filter { !$0.isSeparatorItem }
            precondition(items.count == 17)
            precondition(items[0].representedObject as? String == "system")
            precondition(items.dropFirst().map(\.title) == L10n.sortedLanguages.map(\.title))
            precondition(items.filter { $0.state == .on }.count == 1)
            precondition(items.first { $0.state == .on }!.representedObject as? String == choice)
        }
    }
}
