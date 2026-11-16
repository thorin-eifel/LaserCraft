import Foundation
import AppKit
import Sparkle

/// Automatic updates with Sparkle: the update is downloaded, its signature checked and installed after a click.
///
/// It is switched on by two entries in Info.plist: `SUFeedURL` (the appcast) and `SUPublicEDKey` (your public update key, made with
/// Sparkle's `generate_keys`). Without the key — as in the downloadable beta — nothing starts and the simple "is there a newer
/// release on GitHub" check is used, which never installs anything by itself. See docs/RELEASING.md.
final class AutoUpdater: NSObject {
    static let shared = AutoUpdater()
    private var controller: SPUStandardUpdaterController?

    var isEnabled: Bool { controller != nil }

    /// True when the app is a real bundle and Info.plist carries both entries.
    static func shouldEnable(info: [String: Any], bundlePath: String) -> Bool {
        guard bundlePath.hasSuffix(".app") else { return false }
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty && URL(string: feed)?.scheme == "https"
    }

    override init() {
        super.init()
        if AutoUpdater.shouldEnable(info: Bundle.main.infoDictionary ?? [:], bundlePath: Bundle.main.bundlePath) {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
