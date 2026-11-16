import XCTest
@testable import LaserGRBLCore

final class LocalizationTests: XCTestCase {
    let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")

    func strings(_ lang: String) throws -> [String: String] {
        let url = res.appendingPathComponent("\(lang).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(lang) strings unreadable")
    }

    override func tearDown() { Loc.bundle = .main }

    func useLanguage(_ lang: String) throws {
        Loc.bundle = try XCTUnwrap(Bundle(path: res.appendingPathComponent("\(lang).lproj").path))
    }

    func testAllLanguagesHaveTheSameInterfaceKeys() throws {
        let en = try strings("en")
        let ui = Set(en.keys)
        XCTAssertGreaterThan(ui.count, 150)
        for code in ["de", "fr", "es", "it", "pt-BR"] {
            let lang = try strings(code)
            let keys = Set(lang.keys.filter { !$0.hasPrefix("grbl.") })
            XCTAssertEqual(ui, keys, "\(code) differs: \(ui.symmetricDifference(keys))")
            // format specifiers must survive translation
            for k in en.keys {
                let a = k.components(separatedBy: "%").count, b = (lang[k] ?? "").components(separatedBy: "%").count
                XCTAssertEqual(a, b, "\(code): format mismatch for \(k)")
            }
        }
    }

    /// Dutch and Polish cover the interface only partly: what is there must be a real key with intact format specifiers,
    /// what is missing falls back to the English key.
    func testPartialLanguagesAreConsistentAndFallBackToEnglish() throws {
        let en = try strings("en")
        for code in ["nl", "pl"] {
            let lang = try strings(code)
            XCTAssertGreaterThan(lang.count, 400, "\(code) covers the main interface")
            XCTAssertLessThan(lang.count, en.count + 1)
            for (k, v) in lang {
                XCTAssertNotNil(en[k], "\(code) has a key that does not exist: \(k)")
                XCTAssertEqual(k.components(separatedBy: "%").count, v.components(separatedBy: "%").count, "\(code): format mismatch for \(k)")
                XCTAssertFalse(v.isEmpty, "\(code): empty text for \(k)")
            }
            for k in ["Connect", "Cancel", "Start", "Job History", "state.Idle", "Connected to %@"] {
                XCTAssertNotNil(lang[k], "\(code) \(k)")
            }
            try useLanguage(code)
            XCTAssertNotEqual(Loc.tr("Cancel"), "Cancel")
            let untranslated = en.keys.first { lang[$0] == nil }
            if let k = untranslated { XCTAssertEqual(Loc.tr(k), k, "an untranslated text shows in English") }
        }
    }

    func testGrblMessagesAreTranslated() throws {
        for lang in ["de", "fr"] {
            let s = try strings(lang)
            for n in CodeTables.errors.keys {
                XCTAssertNotNil(s["grbl.error.\(n).title"], "\(lang) error \(n)")
                XCTAssertNotNil(s["grbl.error.\(n).detail"], "\(lang) error \(n)")
            }
            for n in CodeTables.alarms.keys {
                XCTAssertNotNil(s["grbl.alarm.\(n).title"], "\(lang) alarm \(n)")
                XCTAssertNotNil(s["grbl.alarm.\(n).detail"], "\(lang) alarm \(n)")
            }
            for n in CodeTables.settings.keys {
                XCTAssertNotNil(s["grbl.setting.\(n).name"], "\(lang) setting \(n)")
                XCTAssertNotNil(s["grbl.setting.\(n).detail"], "\(lang) setting detail \(n)")
            }
        }
    }

    func testLookupInEachLanguage() throws {
        XCTAssertEqual(L("Connect"), "Connect")
        try useLanguage("de")
        XCTAssertEqual(L("Connect"), "Verbinden")
        XCTAssertEqual(L("Job stopped after %@", "0:01:00"), "Auftrag nach 0:01:00 gestoppt")
        XCTAssertEqual(MachineState.idle.localizedName, "Bereit")
        XCTAssertTrue(GrblParser.describeAlarm(1).contains("Hardware-Endschalter"))
        XCTAssertTrue(GrblParser.describeError(20).hasPrefix("error:20 Nicht unterstützter Befehl"))
        try useLanguage("fr")
        XCTAssertEqual(L("Connect"), "Connecter")
        XCTAssertEqual(MachineState.alarm.localizedName, "Alarme")
        XCTAssertTrue(GrblParser.describeError(20).contains("Commande non prise en charge"))
        XCTAssertEqual(GrblParser.describeSetting(130)?.name, "Course max. axe X")
        XCTAssertEqual(GrblParser.describeSetting(0)?.units, "microsecondes")
        try useLanguage("es")
        XCTAssertEqual(L("Connect"), "Conectar")
        XCTAssertEqual(MachineState.idle.localizedName, "Libre")
        XCTAssertEqual(L("Job stopped after %@", "0:01:00"), "Trabajo detenido tras 0:01:00")
        try useLanguage("it")
        XCTAssertEqual(L("Connect"), "Connetti")
        XCTAssertEqual(MachineState.run.localizedName, "In esecuzione")
        try useLanguage("pt-BR")
        XCTAssertEqual(L("Connect"), "Conectar")
        XCTAssertEqual(L("Resume"), "Retomar")
        // Grbl's own messages are not translated into these languages and fall back to English
        XCTAssertTrue(GrblParser.describeError(20).contains("Unsupported command"))
        try useLanguage("en")
        XCTAssertTrue(GrblParser.describeError(20).contains("Unsupported command"))
    }
}
