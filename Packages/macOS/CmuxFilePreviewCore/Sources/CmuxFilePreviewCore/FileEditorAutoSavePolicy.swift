/// Why a built-in file editor edit may or may not be written to disk (#136).
public enum FileEditorAutoSaveDecision: Equatable, Sendable {
    /// The edit may be written once its debounce delay elapses.
    case save
    /// Auto-save is turned off; behave exactly like the pre-#136 editor.
    case disabled
    /// An input method still holds marked text; committing it early would
    /// write half-typed pinyin.
    case composing
    /// The file is above ``FileEditorAutoSavePolicy/maximumFileBytes``.
    case fileTooLarge
    /// The file moved on disk after the buffer's baseline; writing would
    /// silently clobber the other side's changes.
    case diskChanged
}

/// The rules that decide whether one edit is eligible for auto-save.
///
/// The refusals are ordered so each one is independent of the others: turning
/// auto-save off is indistinguishable from the pre-#136 editor, a composition
/// in progress wins over every size / disk check, an oversized file is skipped
/// without re-reading it, and a drifted file becomes a conflict.
public struct FileEditorAutoSavePolicy: Equatable, Sendable {
    /// Files at or below this size auto-save; larger ones never do.
    public static let maximumFileBytes: Int64 = 5 * 1024 * 1024

    /// Whether the setting is on.
    public var isEnabled: Bool

    /// Creates the policy with the auto-save toggle value.
    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    /// Returns the first refusal that applies, or ``FileEditorAutoSaveDecision/save``.
    ///
    /// - Parameters:
    ///   - isComposing: Whether the text view currently holds marked text.
    ///   - fileByteCount: Current on-disk size of the file being edited.
    ///   - diskStateChanged: Whether the disk fingerprint differs from the
    ///     fingerprint the buffer's baseline was captured from.
    public func decision(
        isComposing: Bool,
        fileByteCount: Int64,
        diskStateChanged: Bool
    ) -> FileEditorAutoSaveDecision {
        if !isEnabled { return .disabled }
        if isComposing { return .composing }
        if fileByteCount > Self.maximumFileBytes { return .fileTooLarge }
        if diskStateChanged { return .diskChanged }
        return .save
    }
}
