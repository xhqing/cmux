import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// `UpdateState.ReleaseNotes` must honor the appcast's own release-notes link before
/// deriving one from the display version. This build's appcast points
/// `sparkle:fullReleaseNotesLink` at this repository's release page; the display-version
/// fallback hardcodes upstream cmux, so preferring it would send users to the wrong project.
@Suite struct ReleaseNotesTests {
    private func makeItem(
        shortVersion: String,
        fullReleaseNotesLink: String? = nil
    ) -> SUAppcastItem {
        var dictionary: [String: Any] = [
            "title": "cmux \(shortVersion)",
            "pubDate": "Mon, 10 Nov 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": "20261110001",
                "sparkle:shortVersionString": shortVersion,
            ],
        ]
        if let fullReleaseNotesLink {
            dictionary["sparkle:fullReleaseNotesLink"] = fullReleaseNotesLink
        }
        return SUAppcastItem(dictionary: dictionary) ?? SUAppcastItem.empty()
    }

    @Test func appcastFullReleaseNotesLinkWins() {
        let item = makeItem(
            shortVersion: "0.65.2.2-r18",
            fullReleaseNotesLink: "https://github.com/xhqing/cmux/releases/tag/v0.65.2.2-r18"
        )

        guard let notes = UpdateState.ReleaseNotes(appcastItem: item) else {
            Issue.record("expected a release-notes link")
            return
        }
        #expect(notes.url.absoluteString
            == "https://github.com/xhqing/cmux/releases/tag/v0.65.2.2-r18")
        #expect(notes.label == "View Release Notes")
    }

    @Test func fallsBackToDisplayVersionDerivation() {
        let item = makeItem(shortVersion: "0.65.2.2")

        guard let notes = UpdateState.ReleaseNotes(appcastItem: item) else {
            Issue.record("expected a release-notes link")
            return
        }
        // Legacy behavior is unchanged when the appcast carries no full release-notes link:
        // the derivation regex takes the first three numeric components (0.65.2) and points
        // at the upstream project, which is exactly why the appcast link must win.
        #expect(notes.url.absoluteString
            == "https://github.com/manaflow-ai/cmux/releases/tag/v0.65.2")
    }
}