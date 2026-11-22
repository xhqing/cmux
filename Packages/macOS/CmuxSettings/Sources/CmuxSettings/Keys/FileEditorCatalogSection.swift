import Foundation

/// Settings under the dotted-id prefix `fileEditor.*`.
///
/// Controls the built-in plain-text file editor (the text preview that the
/// file explorer and `cmux` file routing open for editable text files). This
/// is distinct from the rendered markdown viewer, whose settings live in
/// ``MarkdownCatalogSection``.
public struct FileEditorCatalogSection: SettingCatalogSection {
    /// Inclusive tab-stop range accepted by the editor and JSON schema.
    ///
    /// Keep this as a package-level constant so AppKit, the settings UI, and
    /// the JSON parser all consume the same bounds without repeating literals.
    public static let supportedTabWidthRange: ClosedRange<Int> = 1...8

    /// Inclusive tab-stop range accepted by the editor and JSON schema.
    public var tabWidthRange: ClosedRange<Int> { Self.supportedTabWidthRange }

    /// Inclusive auto-save delay range, in milliseconds, accepted by the
    /// editor and JSON schema (#136).
    ///
    /// Same contract as ``supportedTabWidthRange``: one constant shared by the
    /// editor, the settings UI, and the `cmux.json` parser.
    public static let supportedAutoSaveDelayRange: ClosedRange<Int> = 200...5000

    /// Inclusive auto-save delay range, in milliseconds, accepted by the
    /// editor and JSON schema.
    public var autoSaveDelayRange: ClosedRange<Int> { Self.supportedAutoSaveDelayRange }

    /// Whether long lines soft-wrap at the editor's right edge.
    ///
    /// `false` (the default) preserves the established behavior: lines extend
    /// past the viewport and a horizontal scroller appears. `true` wraps each
    /// line to the visible width and hides the horizontal scroller, the way a
    /// prose editor does. Changing this applies live to open editors.
    public let wordWrap = DefaultsKey<Bool>(
        id: "fileEditor.wordWrap",
        defaultValue: false,
        userDefaultsKey: "fileEditor.wordWrap"
    )

    /// Whether source files receive token colors from the highlight engine.
    public let syntaxHighlighting = DefaultsKey<Bool>(
        id: "fileEditor.syntaxHighlighting",
        defaultValue: true,
        userDefaultsKey: "fileEditor.syntaxHighlighting"
    )

    /// Whether the editor shows a line-number gutter.
    public let lineNumbers = DefaultsKey<Bool>(
        id: "fileEditor.lineNumbers",
        defaultValue: true,
        userDefaultsKey: "fileEditor.lineNumbers"
    )

    /// Whether the editor draws vertical indent guides.
    public let indentGuides = DefaultsKey<Bool>(
        id: "fileEditor.indentGuides",
        defaultValue: true,
        userDefaultsKey: "fileEditor.indentGuides"
    )

    /// Whether the caret's line is highlighted when the selection is empty.
    public let currentLineHighlight = DefaultsKey<Bool>(
        id: "fileEditor.currentLineHighlight",
        defaultValue: true,
        userDefaultsKey: "fileEditor.currentLineHighlight"
    )

    /// Columns per tab stop, used by indent guides.
    public let tabWidth = DefaultsKey<Int>(
        id: "fileEditor.tabWidth",
        defaultValue: 4,
        userDefaultsKey: "fileEditor.tabWidth"
    )

    /// Whether edits are written back to disk after a short idle pause.
    ///
    /// Files above 5 MB, marked text from an input method, and files that
    /// changed on disk after the buffer's baseline are never auto-saved.
    public let autoSave = DefaultsKey<Bool>(
        id: "fileEditor.autoSave",
        defaultValue: true,
        userDefaultsKey: "fileEditor.autoSave"
    )

    /// Idle delay, in milliseconds, before an automatic save.
    public let autoSaveDelay = DefaultsKey<Int>(
        id: "fileEditor.autoSaveDelay",
        defaultValue: 600,
        userDefaultsKey: "fileEditor.autoSaveDelay"
    )

    /// Creates the file editor settings section with its default keys.
    public init() {}
}
