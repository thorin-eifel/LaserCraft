import XCTest
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

@MainActor
final class PreferencesTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.set(nil, forKey: "appearance")
        UserDefaults.standard.set(nil, forKey: "AppleLanguages")
        NSApplication.shared.appearance = nil
    }

    func testLanguageChoiceIsStoredForTheNextLaunch() {
        let model = AppModel()
        model.setLanguage("fr")
        XCTAssertEqual(UserDefaults.standard.array(forKey: "AppleLanguages") as? [String], ["fr"])
        model.setLanguage("de")
        XCTAssertEqual(UserDefaults.standard.array(forKey: "AppleLanguages") as? [String], ["de"])
        model.setLanguage("system")
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        XCTAssertNil(domain?["AppleLanguages"], "the app-specific language must be cleared so macOS decides")
    }

    func testAppearanceSwitchChangesTheApplication() {
        let model = AppModel()
        UserDefaults.standard.set("dark", forKey: "appearance")
        model.applyAppearance()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        UserDefaults.standard.set("light", forKey: "appearance")
        model.applyAppearance()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
        UserDefaults.standard.set("system", forKey: "appearance")
        model.applyAppearance()
        XCTAssertNil(NSApplication.shared.appearance)
    }

    func testResetRestoresDefaults() {
        let model = AppModel()
        UserDefaults.standard.set("dark", forKey: "appearance")
        UserDefaults.standard.set(false, forKey: "soundOnFinish")
        model.resetPreferences()
        XCTAssertNil(UserDefaults.standard.object(forKey: "appearance"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "soundOnFinish"))
        XCTAssertNil(NSApplication.shared.appearance)
    }

    /// Buttons saved while the app was French must not stay French after switching language.
    func testSavedDefaultButtonsFollowTheLanguage() throws {
        let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let langs = try ["en", "de", "fr"].map { try XCTUnwrap(Bundle(path: res.appendingPathComponent("\($0).lproj").path)) }
        var saved = AppModel.defaultButtons()
        // simulate the old behaviour: titles frozen in French, no key
        saved = saved.map { var b = $0; b.title = langs[2].localizedString(forKey: $0.titleKey!, value: nil, table: nil); b.titleKey = nil; b.icon = nil; return b }
        XCTAssertEqual(saved[0].title, "Référencer")
        let fixed = AppModel.migrated(saved, languages: langs)
        XCTAssertTrue(fixed.allSatisfy { $0.titleKey != nil && $0.icon != nil })
        // now shown in the language of the moment
        Loc.bundle = langs[1]
        defer { Loc.bundle = .main }
        XCTAssertEqual(fixed[0].displayTitle, "Referenzfahrt")
        Loc.bundle = langs[0]
        XCTAssertEqual(fixed[0].displayTitle, "Home")
        // a renamed button keeps its own name
        var custom = fixed[1]; custom.title = "My unlock"; custom.titleKey = nil
        XCTAssertEqual(AppModel.migrated([custom], languages: langs)[0].displayTitle, "My unlock")
    }
}
