import Foundation

/// Controls how much on-disk work a git metadata read performs.
///
/// `.full` is the original exact behavior: parse `.git/index`, stat every
/// tracked entry and derive dirty state. `.sidebar` is for background sidebar
/// probes, where branch and HEAD are all the UI needs and the index scan only
/// competes with terminal input for CPU on large repositories.
///
/// A `.sidebar` read deliberately reports a clean state and no index
/// signatures. Callers that need exact dirty state (filesystem events, branch
/// or directory changes) keep using `.full`; the sidebar regains exact state on
/// the next watcher-driven refresh.
public struct GitMetadataReadOptions: Equatable, Sendable {
    public let checksWorkingTreeDirty: Bool

    public init(checksWorkingTreeDirty: Bool) {
        self.checksWorkingTreeDirty = checksWorkingTreeDirty
    }

    /// Exact metadata: branch, dirty state, index signatures and HEAD.
    public static let full = GitMetadataReadOptions(checksWorkingTreeDirty: true)

    /// Cheap sidebar metadata: branch and HEAD only, no index parse and no
    /// per-entry `lstat` scan.
    public static let sidebar = GitMetadataReadOptions(checksWorkingTreeDirty: false)
}
