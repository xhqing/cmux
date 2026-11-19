/// 标题栏铃铛上的未读角标文案。
///
/// 这里只决定「要不要渲染、渲染什么文字」，不改变角标的上限格式：标题栏一直用
/// `min(count, 99)`（`99+` 是 Dock 角标的格式），新增的显示开关不应该顺手把它改掉。
public enum TitlebarBadgePresentation {
    /// 计算标题栏铃铛要显示的角标文案。
    ///
    /// - Parameters:
    ///   - unreadCount: 当前未读通知数。
    ///   - isEnabled: `notifications.titlebarBadge` 开关；关闭时任何未读数都不显示。
    /// - Returns: 要渲染的文案；`nil` 表示这一帧不画角标。
    public static func label(unreadCount: Int, isEnabled: Bool) -> String? {
        guard isEnabled, unreadCount > 0 else { return nil }
        return String(min(unreadCount, 99))
    }
}
