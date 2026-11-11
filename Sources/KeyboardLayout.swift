import AppKit
import Carbon
import GhosttyKit

class KeyboardLayout {
    private enum ModifierTranslationMode {
        case shortcut
        case textInput
    }

    /// Test-only override for the current input source ID.
    #if DEBUG
    static var debugInputSourceIdOverride: String?
    #endif

    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        #if DEBUG
        if let override = debugInputSourceIdOverride { return override }
        #endif
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = Unmanaged<CFString>.fromOpaque(sourceIdPointer).takeUnretainedValue()
            return sourceId as String
        }

        return nil
    }

    /// Translate a physical keyCode to the character AppKit would use for shortcut matching,
    /// preserving command-aware layouts such as "Dvorak - QWERTY Command".
    /// Some CJK input sources lack kTISPropertyUnicodeKeyLayoutData, and others (Korean
    /// 두벌식) have it but UCKeyTranslate still returns non-ASCII characters. In either
    /// case we fall back to TISCopyCurrentASCIICapableKeyboardInputSource().
    static func character(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(
               source,
               forKeyCode: keyCode,
               modifierFlags: modifierFlags,
               mode: .shortcut
           ),
           result.allSatisfy(\.isASCII) {
            return result
        }
        // Current input source has no Unicode layout data or returned a non-ASCII
        // character (e.g. Korean 두벌식 has layout data but UCKeyTranslate still
        // produces Hangul). Fall back to the ASCII-capable source so shortcut
        // matching still works.
        if let asciiSource = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(
               asciiSource,
               forKeyCode: keyCode,
               modifierFlags: modifierFlags,
               mode: .shortcut
           ) {
            return result
        }
        return nil
    }

    /// Selects the event AppKit should interpret for terminal text input.
    ///
    /// Ghostty's auto-detected Option-as-Alt mode must not suppress AppKit's
    /// dead-key state. An explicit `macos-option-as-alt` value remains claimed
    /// by Ghostty, so readline and Emacs keep receiving their Meta chords.
    static func textInputEvent(
        for event: NSEvent,
        translatedEvent: NSEvent,
        config: ghostty_config_t?
    ) -> NSEvent {
        textInputEvent(
            for: event,
            translatedEvent: translatedEvent,
            isDeadKey: isDeadKey(
                forKeyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ),
            config: config
        )
    }

    static func textInputEvent(
        for event: NSEvent,
        translatedEvent: NSEvent,
        isDeadKey: Bool,
        config: ghostty_config_t?
    ) -> NSEvent {
        guard !isOptionAsAltExplicitlyConfigured(in: config),
              isDeadKey else {
            return translatedEvent
        }
        return event
    }

    /// Returns whether the key starts a dead-key composition in the active layout.
    static func isDeadKey(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return false
        }
        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return false }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            keyboardLayout, keyCode, UInt16(kUCKeyActionDisplay),
            translationModifierKeyState(for: modifierFlags, mode: .textInput),
            UInt32(LMGetKbdType()), 0, &deadKeyState, chars.count, &length, &chars
        )
        return status == noErr && deadKeyState != 0
    }

    private static func isOptionAsAltExplicitlyConfigured(in config: ghostty_config_t?) -> Bool {
        guard let config else { return false }
        var value: UnsafePointer<Int8>?
        let key = "macos-option-as-alt"
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count))
    }

    /// Translate a physical keyCode using the current input source exactly as
    /// text input would, including Option/Shift and without ASCII fallback.
    static func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return characterFromInputSource(
            source,
            forKeyCode: keyCode,
            modifierFlags: modifierFlags,
            mode: .textInput,
            lowercased: false
        )
    }

    #if DEBUG
    /// Translate a physical keyCode against a specific keyboard input source
    /// exactly as text input would (Option/Shift applied, no ASCII fallback).
    /// Resolves the source from all installed input sources, so layouts that
    /// are not enabled on the host (e.g. German on a US machine) still
    /// translate. Test-only seam for Option-composition regression coverage.
    static func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        inputSourceID: String
    ) -> String? {
        guard let source = installedInputSource(forID: inputSourceID) else { return nil }
        return characterFromInputSource(
            source,
            forKeyCode: keyCode,
            modifierFlags: modifierFlags,
            mode: .textInput,
            lowercased: false
        )
    }

    private static func installedInputSource(forID inputSourceID: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first
    }
    #endif

    /// Return the ASCII-normalized equivalent of `event.charactersIgnoringModifiers`,
    /// falling back through the ASCII-capable input source for non-Latin input methods.
    /// Use this wherever code compares raw event characters against Latin shortcut keys.
    static func normalizedCharacters(for event: NSEvent) -> String {
        let raw = (event.charactersIgnoringModifiers ?? "").lowercased()
        if raw.allSatisfy(\.isASCII) { return raw }
        if let layoutChar = character(forKeyCode: event.keyCode, modifierFlags: []) {
            return layoutChar
        }
        return raw
    }

    private static func characterFromInputSource(
        _ source: TISInputSource,
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        mode: ModifierTranslationMode,
        lowercased: Bool = true
    ) -> String? {
        guard let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            translationModifierKeyState(for: modifierFlags, mode: mode),
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length)
        return lowercased ? result.lowercased() : result
    }

    private static func translationModifierKeyState(
        for modifierFlags: NSEvent.ModifierFlags,
        mode: ModifierTranslationMode
    ) -> UInt32 {
        let translatedModifiers: NSEvent.ModifierFlags = {
            switch mode {
            case .shortcut:
                return [.shift, .command]
            case .textInput:
                return [.shift, .option]
            }
        }()
        let normalized = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(translatedModifiers)

        var carbonModifiers: Int = 0
        if normalized.contains(.shift) {
            carbonModifiers |= shiftKey
        }
        if normalized.contains(.command) {
            carbonModifiers |= cmdKey
        }
        if normalized.contains(.option) {
            carbonModifiers |= optionKey
        }

        return UInt32((carbonModifiers >> 8) & 0xFF)
    }

    // MARK: - Cold-start warm-up (Issue #44)

    /// Runs the input-source / layout lookups the keystroke path needs, on a
    /// caller-chosen moment instead of on the first key the user types.
    ///
    /// Why: in a fresh process the first `TISCopyCurrentKeyboardInputSource()`
    /// loads HIToolbox's input-source database and the first `LMGetKbdType()`
    /// loads the keyboard-type globals. Measured on the Intel test machine
    /// (macOS 12): 30 ms and 19 ms cold, then 0.00 ms — the same one-time cost
    /// the first keystroke after launch was paying. AppKit's own
    /// `NSEvent.characters(byApplyingModifiers:)` shares those caches, so this
    /// also covers the translation AppKit performs before it delivers
    /// `keyDown`.
    ///
    /// Read-only by design: it never creates or interprets an `NSEvent` and
    /// never touches input state, so it cannot type, start an IME composition,
    /// or move focus. Main thread only — `LMGetKbdType()` reads process-wide
    /// Carbon globals, like every other call in this class.
    static func warmCaches() {
        _ = id
        _ = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
        _ = LMGetKbdType()
        _ = character(forKeyCode: 0)
        _ = character(forKeyCode: 49, modifierFlags: [.shift])
        _ = textInputCharacter(forKeyCode: 0, modifierFlags: [])
        _ = isDeadKey(forKeyCode: 0, modifierFlags: [])
    }

    /// Schedules ``warmCaches()`` once per app session.
    ///
    /// It runs a moment after the caller's turn has finished, so it never
    /// extends surface creation or the first paint, and it is skipped entirely
    /// when the caches are already warm — a repeated call measures 0.00 ms.
    /// The delay is deliberately short: a keystroke typed within it would have
    /// paid the same cost on the old path, so the only new risk is stacking it
    /// with the first frame.
    static func scheduleCacheWarmup(delay: TimeInterval = 0.25) {
        guard !didScheduleCacheWarmup else { return }
        didScheduleCacheWarmup = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let startedAt = ProcessInfo.processInfo.systemUptime
            warmCaches()
            KeyLatencyProbe.recordCost(
                phase: "warmKeyboardLayout",
                milliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            )
        }
    }

    /// Main thread only, like the Carbon layout calls it guards.
    private static var didScheduleCacheWarmup = false
}
