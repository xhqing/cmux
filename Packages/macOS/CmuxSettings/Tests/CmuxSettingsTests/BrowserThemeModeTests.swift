import Foundation
import Testing
@testable import CmuxSettings

@Suite("Browser theme mode")
struct BrowserThemeModeTests {
    @Test func forceDarkIsTheFourthRawValueCase() {
        #expect(BrowserThemeMode.forceDark.rawValue == "forceDark")
        #expect(BrowserThemeMode.allCases == [.system, .light, .dark, .forceDark])
    }

    @Test func userDefaultsStoreRoundTripsForceDark() async throws {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let catalog = SettingCatalog()

        await store.set(.forceDark, for: catalog.browser.theme)
        let value = await store.value(for: catalog.browser.theme)

        #expect(value == .forceDark)
        #expect(defaults.string(forKey: "browserThemeMode") == "forceDark")
    }

    @Test func legacyRawValuesStillDecode() {
        #expect(BrowserThemeMode(rawValue: "system") == .system)
        #expect(BrowserThemeMode(rawValue: "light") == .light)
        #expect(BrowserThemeMode(rawValue: "dark") == .dark)
        #expect(BrowserThemeMode(rawValue: "forceDark") == .forceDark)
    }
}
