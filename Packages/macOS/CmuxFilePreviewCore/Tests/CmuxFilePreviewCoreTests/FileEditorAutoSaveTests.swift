import Foundation
import Testing

@testable import CmuxFilePreviewCore

/// Contract for the built-in file editor's auto-save (xhqing/cmux#136).
///
/// The incident behind the issue: the panel held edits that were never written,
/// another process rewrote the same file, and both sides kept going as if
/// nothing had happened. So the two things these tests protect are:
///
///   1. Stopped typing eventually reaches the disk (once per burst, never
///      mid-composition, never for oversized files).
///   2. A file that moved on disk after the buffer's baseline is never
///      overwritten silently — the write is refused and reported as a conflict
///      so the panel can ask the user which version to keep.
@Suite("File editor auto-save", .serialized)
@MainActor
struct FileEditorAutoSaveTests {
    // MARK: - Policy

    @Test("A healthy edit is written: enabled, idle, small, and based on the current disk state")
    func policyAllowsHealthyWrite() {
        let policy = FileEditorAutoSavePolicy(isEnabled: true)
        #expect(policy.decision(isComposing: false, fileByteCount: 12, diskStateChanged: false) == .save)
    }

    @Test("Auto-save off refuses every write")
    func policyRefusesWhenDisabled() {
        let policy = FileEditorAutoSavePolicy(isEnabled: false)
        #expect(policy.decision(isComposing: false, fileByteCount: 12, diskStateChanged: false) == .disabled)
        // Disabled outranks every other refusal: turning auto-save off must be
        // indistinguishable from the pre-#136 behavior.
        #expect(
            policy.decision(
                isComposing: true,
                fileByteCount: FileEditorAutoSavePolicy.maximumFileBytes + 1,
                diskStateChanged: true
            ) == .disabled
        )
    }

    @Test("Marked text from an input method blocks the write")
    func policyRefusesWhileComposing() {
        let policy = FileEditorAutoSavePolicy(isEnabled: true)
        #expect(policy.decision(isComposing: true, fileByteCount: 12, diskStateChanged: false) == .composing)
        // Half-typed pinyin must never reach the disk, even if everything else
        // about the write would be allowed.
        #expect(
            policy.decision(
                isComposing: true,
                fileByteCount: FileEditorAutoSavePolicy.maximumFileBytes + 1,
                diskStateChanged: true
            ) == .composing
        )
    }

    @Test("Files above 5 MB never auto-save; exactly 5 MB still does")
    func policyCapsFileSize() {
        let policy = FileEditorAutoSavePolicy(isEnabled: true)
        #expect(FileEditorAutoSavePolicy.maximumFileBytes == 5 * 1024 * 1024)
        #expect(
            policy.decision(
                isComposing: false,
                fileByteCount: FileEditorAutoSavePolicy.maximumFileBytes,
                diskStateChanged: false
            ) == .save
        )
        #expect(
            policy.decision(
                isComposing: false,
                fileByteCount: FileEditorAutoSavePolicy.maximumFileBytes + 1,
                diskStateChanged: false
            ) == .fileTooLarge
        )
    }

    @Test("A file that moved on disk after the baseline is a conflict, never a write")
    func policyReportsDiskChange() {
        let policy = FileEditorAutoSavePolicy(isEnabled: true)
        #expect(policy.decision(isComposing: false, fileByteCount: 12, diskStateChanged: true) == .diskChanged)
        // Size is checked before the disk drift: a file that grew past the
        // ceiling while the buffer was open is skipped, not re-read.
        #expect(
            policy.decision(
                isComposing: false,
                fileByteCount: FileEditorAutoSavePolicy.maximumFileBytes + 1,
                diskStateChanged: true
            ) == .fileTooLarge
        )
    }

    // MARK: - Controller

    @Test("A burst of keystrokes writes the last content exactly once, after the delay")
    func burstWritesLastContentOnce() async throws {
        let fileURL = try makeTemporaryFile(containing: "base\n")
        defer { removeTemporaryFile(fileURL) }
        let recorder = AutoSaveRecorder()
        let controller = makeController(fileURL: fileURL, recorder: recorder, isEnabled: true, delayMilliseconds: 60)

        controller.noteEdit(content: "a", isComposing: false)
        controller.noteEdit(content: "ab", isComposing: false)
        controller.noteEdit(content: "abc", isComposing: false)

        let wroteOnce = await waitUntil { recorder.writtenContents == ["abc"] }
        #expect(wroteOnce, "A debounced burst must write the last buffer exactly once")
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "abc")
        #expect(recorder.outcomes == [.saved])
        #expect(!controller.hasPendingAutoSave)
    }

    @Test("Editing after a successful save saves again — the save advanced the baseline")
    func laterEditSavesAgain() async throws {
        let fileURL = try makeTemporaryFile(containing: "base\n")
        defer { removeTemporaryFile(fileURL) }
        let recorder = AutoSaveRecorder()
        let controller = makeController(fileURL: fileURL, recorder: recorder, isEnabled: true, delayMilliseconds: 60)

        controller.noteEdit(content: "first", isComposing: false)
        let savedFirst = await waitUntil { recorder.writtenContents == ["first"] }
        #expect(savedFirst)
        controller.noteEdit(content: "second", isComposing: false)
        let savedSecond = await waitUntil { recorder.writtenContents == ["first", "second"] }
        #expect(savedSecond)

        // The controller's own write must not look like an external change;
        // otherwise the second edit above would have been refused as a conflict.
        #expect(recorder.outcomes == [.saved, .saved])
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "second")
    }

    @Test("An external write during the debounce window is a conflict, not an overwrite")
    func externalWriteBecomesConflict() async throws {
        let fileURL = try makeTemporaryFile(containing: "base\n")
        defer { removeTemporaryFile(fileURL) }
        let recorder = AutoSaveRecorder()
        let controller = makeController(fileURL: fileURL, recorder: recorder, isEnabled: true, delayMilliseconds: 60)

        controller.noteEdit(content: "mine\n", isComposing: false)
        // The other side of the incident: git checkout / merge rewrites the file
        // between the keystroke and the debounced write.
        try "external\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let conflicted = await waitUntil { recorder.outcomes == [.conflict] }
        #expect(conflicted)
        #expect(recorder.writtenContents.isEmpty, "A conflicted auto-save must not touch the disk")
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "external\n")
        #expect(!controller.hasPendingAutoSave)
    }

    @Test("Adopting the disk version lets the next edit save")
    func rebaseAfterConflictSaves() async throws {
        let fileURL = try makeTemporaryFile(containing: "base\n")
        defer { removeTemporaryFile(fileURL) }
        let recorder = AutoSaveRecorder()
        let controller = makeController(fileURL: fileURL, recorder: recorder, isEnabled: true, delayMilliseconds: 60)

        controller.noteEdit(content: "mine\n", isComposing: false)
        try "external\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let conflicted = await waitUntil { recorder.outcomes == [.conflict] }
        #expect(conflicted)

        // The user picked "load disk version", so the buffer is based on the
        // external content now and the next edit is an ordinary save.
        controller.rebaseToCurrentDiskState()
        controller.noteEdit(content: "external plus my edit\n", isComposing: false)

        let savedRebased = await waitUntil { recorder.writtenContents == ["external plus my edit\n"] }
        #expect(savedRebased)
        #expect(recorder.outcomes == [.conflict, .saved])
    }

    @Test("Auto-save off leaves the file untouched")
    func disabledNeverWrites() async throws {
        let fileURL = try makeTemporaryFile(containing: "base\n")
        defer { removeTemporaryFile(fileURL) }
        let recorder = AutoSaveRecorder()
        let controller = makeController(fileURL: fileURL, recorder: recorder, isEnabled: false, delayMilliseconds: 60)

        controller.noteEdit(content: "ignored", isComposing: false)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(recorder.writtenContents.isEmpty)
        #expect(recorder.outcomes.isEmpty)
        #expect(!controller.hasPendingAutoSave)
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "base\n")
    }

    @Test("Marked text never writes; the committed composition saves")
    func composingDefersUntilCommit() async throws {
        let fileURL = try makeTemporaryFile(containing: "base\n")
        defer { removeTemporaryFile(fileURL) }
        let recorder = AutoSaveRecorder()
        let controller = makeController(fileURL: fileURL, recorder: recorder, isEnabled: true, delayMilliseconds: 60)

        controller.noteEdit(content: "半", isComposing: true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(recorder.writtenContents.isEmpty, "Marked text must not reach the disk")
        #expect(recorder.outcomes.isEmpty)
        let untouched = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(untouched == "base\n")

        // The input method commits and the panel reports the final content
        // with the composition finished; that edit is an ordinary save.
        controller.noteEdit(content: "半成品", isComposing: false)
        let savedComposition = await waitUntil { recorder.writtenContents == ["半成品"] }
        #expect(savedComposition)
        #expect(recorder.outcomes == [.saved])
    }

    @Test("Files above the 5 MB ceiling are never auto-saved")
    func oversizedFileIsSkipped() async throws {
        let fileURL = try makeTemporaryFile(containing: "")
        defer { removeTemporaryFile(fileURL) }
        let largeBytes = Int(FileEditorAutoSavePolicy.maximumFileBytes) + 1
        try Data(count: largeBytes).write(to: fileURL)
        let recorder = AutoSaveRecorder()
        let controller = makeController(fileURL: fileURL, recorder: recorder, isEnabled: true, delayMilliseconds: 60)

        controller.noteEdit(content: "small", isComposing: false)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(recorder.writtenContents.isEmpty)
        #expect(recorder.outcomes.isEmpty)
        let size = try #require(attributedSize(of: fileURL))
        #expect(size == largeBytes)
    }

    @Test("Cancelling a pending auto-save writes nothing")
    func cancelledWriteIsDropped() async throws {
        let fileURL = try makeTemporaryFile(containing: "base\n")
        defer { removeTemporaryFile(fileURL) }
        let recorder = AutoSaveRecorder()
        let controller = makeController(fileURL: fileURL, recorder: recorder, isEnabled: true, delayMilliseconds: 60)

        controller.noteEdit(content: "pending", isComposing: false)
        #expect(controller.hasPendingAutoSave)
        // Closing the panel or the window cancels the scheduled write.
        controller.cancelPendingAutoSave()
        #expect(!controller.hasPendingAutoSave)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(recorder.writtenContents.isEmpty)
        #expect(recorder.outcomes.isEmpty)
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "base\n")
    }

    // MARK: - Helpers

    private func makeController(
        fileURL: URL,
        recorder: AutoSaveRecorder,
        isEnabled: Bool,
        delayMilliseconds: Int
    ) -> FileEditorAutoSaveController {
        let controller = FileEditorAutoSaveController(
            filePath: fileURL.path,
            encoding: .utf8,
            settings: {
                FileEditorAutoSaveSettings(
                    isEnabled: isEnabled,
                    delayMilliseconds: delayMilliseconds
                )
            },
            writer: makeWriter(recorder),
            onOutcome: { recorder.recordOutcome($0) }
        )
        controller.rebaseToCurrentDiskState()
        return controller
    }

    private func makeWriter(_ recorder: AutoSaveRecorder) -> FileEditorAutoSaveController.Writer {
        { content, url, encoding in
            await MainActor.run { recorder.recordWrite(content) }
            guard let data = content.data(using: encoding) else { return false }
            do {
                try data.write(to: url)
                return true
            } catch {
                return false
            }
        }
    }

    private func makeTemporaryFile(containing contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-editor-autosave-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "note.txt")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func removeTemporaryFile(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func attributedSize(of fileURL: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// Polls a debounced side effect instead of sleeping a fixed span, so a
    /// slower CI runner makes the test slower rather than flaky.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Records writes and outcomes from the controller's callbacks.
@MainActor
private final class AutoSaveRecorder {
    private(set) var writtenContents: [String] = []
    private(set) var outcomes: [FileEditorAutoSaveOutcome] = []

    func recordWrite(_ content: String) {
        writtenContents.append(content)
    }

    func recordOutcome(_ outcome: FileEditorAutoSaveOutcome) {
        outcomes.append(outcome)
    }
}
