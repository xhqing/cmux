public import Foundation

/// The auto-save behavior the panel currently wants, read fresh on every edit
/// so a settings change applies without rebuilding the controller.
public struct FileEditorAutoSaveSettings: Equatable, Sendable {
    /// Whether auto-save is on.
    public var isEnabled: Bool

    /// Idle delay before the debounced write.
    public var delayMilliseconds: Int

    /// Creates the settings snapshot.
    public init(isEnabled: Bool, delayMilliseconds: Int) {
        self.isEnabled = isEnabled
        self.delayMilliseconds = delayMilliseconds
    }
}

/// What happened to one scheduled auto-save.
public enum FileEditorAutoSaveOutcome: Equatable, Sendable {
    /// The bytes were written and the baseline advanced.
    case saved
    /// The file moved on disk after the baseline; nothing was written.
    case conflict
    /// The write itself failed.
    case failed
}

/// Debounces editor edits and writes the buffer back to disk, refusing to
/// overwrite a file that changed on disk after the buffer's baseline (#136).
///
/// The controller owns its own disk fingerprint. Watcher notifications must
/// never advance it — only this controller's own successful write and an
/// explicit ``rebaseToCurrentDiskState()`` (loading the disk version, or a
/// manual save) do. Otherwise an external change would be mistaken for the
/// buffer's baseline and the next auto-save would silently clobber it.
@MainActor
public final class FileEditorAutoSaveController {
    /// Writes `content` to the file and reports whether the bytes landed.
    public typealias Writer = @Sendable (String, URL, String.Encoding) async -> Bool

    private let filePath: String
    private let encoding: String.Encoding
    private let settings: @MainActor () -> FileEditorAutoSaveSettings
    private let writer: Writer
    private let onOutcome: (@MainActor (FileEditorAutoSaveOutcome) -> Void)?

    /// Fingerprint of the disk state the buffer is based on.
    private var baseline: FileEditorDiskState
    private var pendingTask: Task<Void, Never>?
    private var scheduleGeneration = 0

    /// Creates a controller for one editable file.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path of the edited file.
    ///   - encoding: Encoding used to turn the buffer into bytes.
    ///   - settings: Read on every edit and again when the delay fires.
    ///   - writer: Performs the write; the default writes the bytes as-is.
    ///   - onOutcome: Reports a completed write attempt (or a conflict).
    public init(
        filePath: String,
        encoding: String.Encoding,
        settings: @escaping @MainActor () -> FileEditorAutoSaveSettings,
        writer: @escaping Writer = { content, url, encoding in
            guard let data = content.data(using: encoding) else { return false }
            do {
                try data.write(to: url)
                return true
            } catch {
                return false
            }
        },
        onOutcome: (@MainActor (FileEditorAutoSaveOutcome) -> Void)? = nil
    ) {
        self.filePath = filePath
        self.encoding = encoding
        self.settings = settings
        self.writer = writer
        self.onOutcome = onOutcome
        self.baseline = FileEditorDiskState.capture(path: filePath)
    }

    /// Whether a debounced write is still scheduled.
    public var hasPendingAutoSave: Bool {
        pendingTask != nil
    }

    /// Adopts the current disk state as the buffer's baseline and drops any
    /// scheduled write. Called when the panel loads the disk version, or after
    /// a manual save already wrote the buffer.
    public func rebaseToCurrentDiskState() {
        cancelPendingAutoSave()
        baseline = FileEditorDiskState.capture(path: filePath)
    }

    /// Schedules (or re-schedules) the debounced write for this edit.
    ///
    /// Every call cancels the previous schedule, so a burst of keystrokes
    /// writes only the last buffer. A refusal at scheduling time schedules
    /// nothing and reports nothing; the panel already knows why (auto-save off,
    /// composing, oversized) or learns about the drift from the watcher.
    public func noteEdit(content: String, isComposing: Bool) {
        cancelPendingAutoSave()

        let configuration = settings()
        let policy = FileEditorAutoSavePolicy(isEnabled: configuration.isEnabled)
        let diskState = FileEditorDiskState.capture(path: filePath)
        let decision = policy.decision(
            isComposing: isComposing,
            fileByteCount: diskState.byteCount,
            diskStateChanged: diskState != baseline
        )
        guard decision == .save else { return }

        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let delay = max(1, configuration.delayMilliseconds)
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.scheduleGeneration == generation else { return }
            self.pendingTask = nil
            await self.performWrite(content: content, isComposing: isComposing)
        }
    }

    /// Drops the scheduled write so closing a panel never writes behind the
    /// user's back.
    public func cancelPendingAutoSave() {
        scheduleGeneration &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// Re-checks the disk right before writing: the file may have moved during
    /// the debounce window.
    private func performWrite(content: String, isComposing: Bool) async {
        let configuration = settings()
        let policy = FileEditorAutoSavePolicy(isEnabled: configuration.isEnabled)
        let diskState = FileEditorDiskState.capture(path: filePath)
        let decision = policy.decision(
            isComposing: isComposing,
            fileByteCount: diskState.byteCount,
            diskStateChanged: diskState != baseline
        )
        switch decision {
        case .save:
            break
        case .diskChanged:
            onOutcome?(.conflict)
            return
        case .disabled, .composing, .fileTooLarge:
            return
        }

        let didWrite = await writer(content, URL(fileURLWithPath: filePath), encoding)
        guard didWrite else {
            onOutcome?(.failed)
            return
        }
        // Advance the baseline past our own write, or the next edit would look
        // like an external change.
        baseline = FileEditorDiskState.capture(path: filePath)
        onOutcome?(.saved)
    }
}
