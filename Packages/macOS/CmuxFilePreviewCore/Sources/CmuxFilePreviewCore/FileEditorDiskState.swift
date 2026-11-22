import Darwin
import Foundation

/// A fingerprint of the on-disk file a text buffer is based on (#136).
///
/// Device and inode catch editors that replace the file atomically (a `git
/// checkout` writes a new inode), size catches in-place rewrites, and the
/// second + nanosecond modification time catches same-size rewrites. The app's
/// watcher has its own equivalent snapshot (`FilePreviewFileState`); this type
/// deliberately stays in the package so the auto-save controller can compare
/// fingerprints without reaching into app state.
public struct FileEditorDiskState: Equatable, Sendable {
    /// Current size in bytes; `0` when the file does not exist.
    public let byteCount: Int64

    private let exists: Bool
    private let device: Int64
    private let inode: UInt64
    private let size: Int64
    private let modificationSeconds: Int64
    private let modificationNanoseconds: Int64

    /// Captures the current fingerprint of `path`.
    ///
    /// A missing file yields an all-zero state with `byteCount == 0`, which
    /// compares unequal to any state of an existing file.
    public static func capture(path: String) -> FileEditorDiskState {
        var attributes = stat()
        guard stat(path, &attributes) == 0 else {
            return FileEditorDiskState(
                byteCount: 0,
                exists: false,
                device: 0,
                inode: 0,
                size: 0,
                modificationSeconds: 0,
                modificationNanoseconds: 0
            )
        }
        let size = Int64(attributes.st_size)
        return FileEditorDiskState(
            byteCount: size,
            exists: true,
            device: Int64(attributes.st_dev),
            inode: UInt64(attributes.st_ino),
            size: size,
            modificationSeconds: Int64(attributes.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(attributes.st_mtimespec.tv_nsec)
        )
    }

    private init(
        byteCount: Int64,
        exists: Bool,
        device: Int64,
        inode: UInt64,
        size: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64
    ) {
        self.byteCount = byteCount
        self.exists = exists
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }
}
