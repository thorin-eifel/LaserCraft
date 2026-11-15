import Foundation

/// A version like `1.0.0`, `v1.0.0-beta.2` or `1.2.3-rc.1`. A pre-release is older than the release it leads up to.
public struct AppVersion: Comparable, CustomStringConvertible, Equatable {
    public var major: Int, minor: Int, patch: Int
    /// `("beta", 2)` for `-beta.2`; nil for a final release.
    public var prerelease: (label: String, number: Int)?

    public init(major: Int, minor: Int, patch: Int, prerelease: (label: String, number: Int)? = nil) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard let core = parts.first else { return nil }
        let nums = core.split(separator: ".").map { Int($0) }
        guard nums.count >= 1, nums.count <= 3, !nums.contains(where: { $0 == nil }) else { return nil }
        major = nums[0] ?? 0; minor = nums.count > 1 ? (nums[1] ?? 0) : 0; patch = nums.count > 2 ? (nums[2] ?? 0) : 0
        if parts.count == 2 {
            let pre = parts[1].split(separator: ".")
            let label = pre.first.map(String.init) ?? ""
            let number = pre.count > 1 ? (Int(pre[1]) ?? 0) : 0
            prerelease = (label.lowercased(), number)
        } else { prerelease = nil }
    }

    public var isPrerelease: Bool { prerelease != nil }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard let p = prerelease else { return core }
        return core + "-" + p.label + (p.number > 0 ? ".\(p.number)" : "")
    }

    private static let order = ["alpha": 0, "beta": 1, "rc": 2]

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        a.major == b.major && a.minor == b.minor && a.patch == b.patch
            && a.prerelease?.label == b.prerelease?.label && a.prerelease?.number == b.prerelease?.number
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false            // a final release is newer than its pre-releases
        case (_, nil): return true
        case let (x?, y?):
            let ox = order[x.label] ?? 0, oy = order[y.label] ?? 0
            return ox != oy ? ox < oy : x.number < y.number
        }
    }
}

public struct ReleaseInfo: Equatable {
    public var tag: String
    public var name: String
    public var url: URL
    public var prerelease: Bool
    public var version: AppVersion?
}

/// Looks for newer LaserCraft releases on GitHub. Nothing is downloaded or installed: the person is pointed at the release page.
public enum UpdateChecker {
    public static let releasesURL = URL(string: "https://api.github.com/repos/thorin-eifel/LaserCraft/releases?per_page=15")!

    /// Reads GitHub's `releases` JSON; drafts are ignored.
    public static func parseReleases(_ data: Data) throws -> [ReleaseInfo] {
        struct Item: Decodable { let tag_name: String; let name: String?; let html_url: String; let draft: Bool?; let prerelease: Bool? }
        let items = try JSONDecoder().decode([Item].self, from: data)
        return items.compactMap { i in
            guard i.draft != true, let url = URL(string: i.html_url) else { return nil }
            return ReleaseInfo(tag: i.tag_name, name: i.name ?? i.tag_name, url: url, prerelease: i.prerelease == true, version: AppVersion(i.tag_name))
        }
    }

    /// The newest release that is newer than `current`. Pre-releases only count when the running version is one too.
    public static func newest(in releases: [ReleaseInfo], than current: AppVersion) -> ReleaseInfo? {
        releases
            .filter { r in
                guard let v = r.version, v > current else { return false }
                return !(r.prerelease || v.isPrerelease) || current.isPrerelease
            }
            .max { ($0.version ?? AppVersion(major: 0, minor: 0, patch: 0)) < ($1.version ?? AppVersion(major: 0, minor: 0, patch: 0)) }
    }

    /// Downloads the release list and finds a newer one. Calls back on the main queue.
    public static func check(current: AppVersion, session: URLSession = .shared,
                             completion: @escaping (Result<ReleaseInfo?, Error>) -> Void) {
        var request = URLRequest(url: releasesURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LaserCraft/\(current)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, _, error in
            let result: Result<ReleaseInfo?, Error>
            if let error = error { result = .failure(error) }
            else if let data = data {
                do { result = .success(newest(in: try parseReleases(data), than: current)) } catch { result = .failure(error) }
            } else { result = .success(nil) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
