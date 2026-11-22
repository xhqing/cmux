import CmuxFilePreviewCore
import CmuxSettings
import Foundation

/// Persistent File Preview code-view chrome settings.
///
/// Keys live under `fileEditor.*` and are shared by the Settings catalog,
/// `~/.config/cmux/cmux.json`, and the text editor. Defaults match VS Code /
/// Cursor / Zed: highlighting, line numbers, indent guides, and current-line
/// highlight are on.
struct FilePreviewEditorSettings {
    let defaults: UserDefaults
    /// The catalog is the sole owner of file-editor keys, defaults, and
    /// validation bounds. It is injected as a value so tests and composition
    /// roots can use an explicit settings definition.
    let catalog: FileEditorCatalogSection

    /// Creates a settings reader backed by the supplied defaults store.
    ///
    /// - Parameter defaults: Defaults store used for runtime reads.
    init(defaults: UserDefaults, catalog: FileEditorCatalogSection = FileEditorCatalogSection()) {
        self.defaults = defaults
        self.catalog = catalog
    }

    func isEnabled(
        key: String,
        default defaultValue: Bool
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    var tabWidth: Int {
        let stored = defaults.object(forKey: catalog.tabWidth.userDefaultsKey) as? Int
            ?? catalog.tabWidth.defaultValue
        return min(
            max(stored, catalog.tabWidthRange.lowerBound),
            catalog.tabWidthRange.upperBound
        )
    }

    /// Whether the editor writes edits back to disk after an idle pause (#136).
    var isAutoSaveEnabled: Bool {
        isEnabled(
            key: catalog.autoSave.userDefaultsKey,
            default: catalog.autoSave.defaultValue
        )
    }

    /// Idle delay before an automatic save, clamped to the catalog's range (#136).
    var autoSaveDelayMilliseconds: Int {
        let stored = defaults.object(forKey: catalog.autoSaveDelay.userDefaultsKey) as? Int
            ?? catalog.autoSaveDelay.defaultValue
        return min(
            max(stored, catalog.autoSaveDelayRange.lowerBound),
            catalog.autoSaveDelayRange.upperBound
        )
    }

    /// The snapshot the built-in file editor's auto-save controller reads on
    /// every edit, so a settings change applies to already-open editors.
    var autoSaveSettings: FileEditorAutoSaveSettings {
        FileEditorAutoSaveSettings(
            isEnabled: isAutoSaveEnabled,
            delayMilliseconds: autoSaveDelayMilliseconds
        )
    }
}
