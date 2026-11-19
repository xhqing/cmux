import Testing
@testable import CmuxNotifications

@Suite("Titlebar badge presentation")
struct TitlebarBadgePresentationTests {
    @Test func disabledNeverRendersBadge() {
        #expect(TitlebarBadgePresentation.label(unreadCount: 1, isEnabled: false) == nil)
        #expect(TitlebarBadgePresentation.label(unreadCount: 42, isEnabled: false) == nil)
    }

    @Test func zeroUnreadNeverRendersBadge() {
        #expect(TitlebarBadgePresentation.label(unreadCount: 0, isEnabled: true) == nil)
        #expect(TitlebarBadgePresentation.label(unreadCount: 0, isEnabled: false) == nil)
    }

    @Test func enabledRendersUnreadCount() {
        #expect(TitlebarBadgePresentation.label(unreadCount: 1, isEnabled: true) == "1")
        #expect(TitlebarBadgePresentation.label(unreadCount: 42, isEnabled: true) == "42")
    }

    @Test func largeCountsKeepTheExistingNinetyNineCap() {
        // 现有标题栏角标显示的是 min(count, 99)（「99+」是 Dock 角标的格式），
        // 新增开关只控制显不显示，不能顺手改掉这个上限的呈现。
        #expect(TitlebarBadgePresentation.label(unreadCount: 99, isEnabled: true) == "99")
        #expect(TitlebarBadgePresentation.label(unreadCount: 150, isEnabled: true) == "99")
    }
}
