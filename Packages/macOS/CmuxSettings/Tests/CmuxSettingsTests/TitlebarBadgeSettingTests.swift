import Foundation
import Testing
@testable import CmuxSettings

@Suite("notifications.titlebarBadge")
struct TitlebarBadgeSettingTests {
    @Test func catalogExposesTheSettingWithOnByDefault() {
        let key = SettingCatalog().notifications.titlebarBadge
        #expect(key.id == "notifications.titlebarBadge")
        #expect(key.defaultValue == true, "默认必须是 true：升级后行为与现在完全一致")
    }

    @Test func storedFalseIsReadBackAndMissingValueFallsBackToOn() {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let key = SettingCatalog().notifications.titlebarBadge

        #expect(settings.value(for: key) == true, "没有存储值时默认开启")

        settings.set(false, for: key)
        #expect(settings.value(for: key) == false)

        settings.reset(for: key)
        #expect(settings.value(for: key) == true)
    }
}
