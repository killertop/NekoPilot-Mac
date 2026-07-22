import Foundation
import Testing
@testable import NekoPilotCore

@Suite("GitHub stable-release update policy")
struct GitHubReleaseCheckerTests {
    @Test("Semantic versions compare without treating prerelease text as a newer patch")
    func comparesSemanticVersions() {
        #expect(GitHubReleaseChecker.isVersionNewer("v1.0.8", than: "1.0.7"))
        #expect(GitHubReleaseChecker.isVersionNewer("2.0", than: "1.9.9"))
        #expect(!GitHubReleaseChecker.isVersionNewer("v1.0.7", than: "1.0.7"))
        #expect(!GitHubReleaseChecker.isVersionNewer("v1.0.6", than: "1.0.7"))
        #expect(!GitHubReleaseChecker.isVersionNewer("not-a-version", than: "1.0.7"))
        #expect(!GitHubReleaseChecker.isVersionNewer(
            "999999999999999999999999999999999999.1.1",
            than: "1.0.7"
        ))
    }

    @Test("Only the canonical project release page is accepted")
    func acceptsOnlyCanonicalReleaseURL() {
        #expect(GitHubReleaseChecker.safeReleaseURL(
            "https://github.com/killertop/NekoPilot-Mac/releases/tag/v1.0.8"
        ) != nil)
        #expect(GitHubReleaseChecker.safeReleaseURL(
            "https://example.com/killertop/NekoPilot-Mac/releases/tag/v1.0.8"
        ) == nil)
        #expect(GitHubReleaseChecker.safeReleaseURL(
            "https://github.com/other/project/releases/tag/v1.0.8"
        ) == nil)
        #expect(GitHubReleaseChecker.safeReleaseURL(
            "https://github.com:444/killertop/NekoPilot-Mac/releases/tag/v1.0.8"
        ) == nil)
    }

    @Test("Checks are limited to once every twenty-four hours")
    func limitsCheckFrequency() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(GitHubReleaseChecker.isCheckDue(lastCheck: nil, now: now))
        #expect(!GitHubReleaseChecker.isCheckDue(
            lastCheck: now.timeIntervalSince1970 - 60,
            now: now
        ))
        #expect(GitHubReleaseChecker.isCheckDue(
            lastCheck: now.timeIntervalSince1970 - GitHubReleaseChecker.interval,
            now: now
        ))
    }
}
