import XCTest
@testable import LaserGRBLCore

final class UpdateTests: XCTestCase {
    func v(_ s: String) -> AppVersion { AppVersion(s)! }

    func testParsingAndPrinting() {
        XCTAssertEqual(v("1.0.0").description, "1.0.0")
        XCTAssertEqual(v("v1.0.0-beta.2").description, "1.0.0-beta.2")
        XCTAssertEqual(v("2.1").description, "2.1.0")
        XCTAssertEqual(v("1.0.0-rc.1").prerelease?.label, "rc")
        XCTAssertNil(AppVersion("nonsense"))
        XCTAssertNil(AppVersion("1.x.0"))
        XCTAssertNil(AppVersion(""))
    }

    func testOrdering() {
        XCTAssertLessThan(v("1.0.0-beta.1"), v("1.0.0-beta.2"))
        XCTAssertLessThan(v("1.0.0-beta.9"), v("1.0.0-rc.1"))
        XCTAssertLessThan(v("1.0.0-alpha.3"), v("1.0.0-beta.1"))
        XCTAssertLessThan(v("1.0.0-rc.3"), v("1.0.0"), "a release is newer than its pre-releases")
        XCTAssertLessThan(v("1.0.0"), v("1.0.1"))
        XCTAssertLessThan(v("1.9.9"), v("1.10.0"), "numbers, not text")
        XCTAssertLessThan(v("0.9.0"), v("1.0.0-beta.1"))
        XCTAssertEqual(v("v1.2.3"), v("1.2.3"))
    }

    let json = """
    [
      {"tag_name": "v1.0.0-beta.3", "name": "Release 1 Beta 3", "html_url": "https://github.com/thorin-eifel/LaserCraft/releases/tag/v1.0.0-beta.3", "draft": false, "prerelease": true},
      {"tag_name": "v1.0.0-beta.2", "name": "Release 1 Beta 2", "html_url": "https://github.com/thorin-eifel/LaserCraft/releases/tag/v1.0.0-beta.2", "draft": false, "prerelease": true},
      {"tag_name": "v9.9.9", "name": "Draft", "html_url": "https://github.com/x/y", "draft": true, "prerelease": false},
      {"tag_name": "v1.0.0", "name": "Release 1", "html_url": "https://github.com/thorin-eifel/LaserCraft/releases/tag/v1.0.0", "draft": false, "prerelease": false},
      {"tag_name": "weekly-build", "name": "not a version", "html_url": "https://github.com/x/z", "draft": false, "prerelease": false}
    ]
    """.data(using: .utf8)!

    func testReadingGitHubReleases() throws {
        let list = try UpdateChecker.parseReleases(json)
        XCTAssertEqual(list.map { $0.tag }, ["v1.0.0-beta.3", "v1.0.0-beta.2", "v1.0.0", "weekly-build"], "drafts are dropped")
        XCTAssertNil(list.last?.version)
        XCTAssertThrowsError(try UpdateChecker.parseReleases(Data("not json".utf8)))
    }

    func testBetaTestersGetBetasAndFinalReleases() throws {
        let list = try UpdateChecker.parseReleases(json)
        XCTAssertEqual(UpdateChecker.newest(in: list, than: v("1.0.0-beta.1"))?.tag, "v1.0.0", "the final release beats every beta")
        XCTAssertNil(UpdateChecker.newest(in: Array(list.dropFirst(2)).filter { $0.tag != "v1.0.0" }, than: v("1.0.0-beta.2")))
        let onlyBetas = Array(list.prefix(2))
        XCTAssertEqual(UpdateChecker.newest(in: onlyBetas, than: v("1.0.0-beta.2"))?.tag, "v1.0.0-beta.3")
    }

    func testPeopleOnAFinalVersionAreNotOfferedBetas() throws {
        let list = try UpdateChecker.parseReleases(json)
        XCTAssertNil(UpdateChecker.newest(in: list, than: v("1.0.0")), "nothing newer than 1.0.0")
        let betasOnly = Array(list.prefix(2))
        XCTAssertNil(UpdateChecker.newest(in: betasOnly, than: v("0.9.0")), "betas are not offered to final-release users")
    }
}
