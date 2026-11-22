import Foundation
import Testing

@testable import CmuxSettings

/// The `fileEditor.autoSave*` keys (xhqing/cmux#136).
///
/// The catalog is the single owner of defaults and bounds, and the JSON schema
/// carries the same numbers so `cmux.json` accepts them. `scripts/tests/test_file_editor_autosave_schema.py`
/// keeps the two in step; these tests pin the catalog side.
@Suite("File editor auto-save settings")
struct FileEditorAutoSaveSettingTests {
    @Test("Auto-save ships on, with a 600 ms delay inside 200–5000 ms")
    func catalogDefaultsAndBounds() {
        let catalog = FileEditorCatalogSection()

        #expect(catalog.autoSave.id == "fileEditor.autoSave")
        #expect(catalog.autoSave.userDefaultsKey == "fileEditor.autoSave")
        #expect(catalog.autoSave.defaultValue == true)

        #expect(catalog.autoSaveDelay.id == "fileEditor.autoSaveDelay")
        #expect(catalog.autoSaveDelay.userDefaultsKey == "fileEditor.autoSaveDelay")
        #expect(catalog.autoSaveDelay.defaultValue == 600)
        #expect(catalog.autoSaveDelayRange == 200...5000)
    }

    @Test("Both keys reach the settings catalog, so cmux.json and the settings UI can address them")
    func catalogReachesBothKeys() {
        let ids = Set(SettingCatalog().all.map(\.id))
        #expect(ids.contains("fileEditor.autoSave"))
        #expect(ids.contains("fileEditor.autoSaveDelay"))
    }
}
