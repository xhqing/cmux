import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser force dark settings")
struct BrowserForceDarkSettingsTests {
    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "cmux.tests.force-dark.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func defaultsToNoExcludedHosts() throws {
        let (defaults, _) = try makeDefaults()
        #expect(BrowserForceDarkSettings.excludedHosts(defaults: defaults).isEmpty)
        #expect(!BrowserForceDarkSettings.isHostExcluded("facebook.com", defaults: defaults))
    }

    @Test func storesNormalizedDeduplicatedHosts() throws {
        let (defaults, _) = try makeDefaults()
        BrowserForceDarkSettings.setExcludedHosts(
            [" Facebook.com ", "facebook.com", "BUSINESS.facebook.com.", ""],
            defaults: defaults
        )
        #expect(Set(BrowserForceDarkSettings.excludedHosts(defaults: defaults)) == [
            "facebook.com",
            "business.facebook.com",
        ])
        #expect(BrowserForceDarkSettings.isHostExcluded("business.facebook.com", defaults: defaults))
        #expect(BrowserForceDarkSettings.isHostExcluded("www.facebook.com", defaults: defaults))
        #expect(!BrowserForceDarkSettings.isHostExcluded("example.com", defaults: defaults))
    }

    @Test func togglesOneHostAndPersists() throws {
        let (defaults, suiteName) = try makeDefaults()
        BrowserForceDarkSettings.setHostExcluded("Business.Facebook.com", excluded: true, defaults: defaults)

        let other = try #require(UserDefaults(suiteName: suiteName))
        #expect(BrowserForceDarkSettings.isHostExcluded("business.facebook.com", defaults: other))

        BrowserForceDarkSettings.setHostExcluded("business.facebook.com", excluded: false, defaults: other)
        #expect(!BrowserForceDarkSettings.isHostExcluded("business.facebook.com", defaults: defaults))
    }

    @Test func removingOneHostKeepsUnrelatedExceptions() throws {
        let (defaults, _) = try makeDefaults()
        BrowserForceDarkSettings.setExcludedHosts(["facebook.com", "example.com"], defaults: defaults)
        BrowserForceDarkSettings.setHostExcluded("example.com", excluded: false, defaults: defaults)
        #expect(BrowserForceDarkSettings.isHostExcluded("facebook.com", defaults: defaults))
        #expect(!BrowserForceDarkSettings.isHostExcluded("example.com", defaults: defaults))
    }
}
