import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitMetadataReadOptionsTests {
    /// The cheap read must not parse `.git/index` or stat tracked files. On a
    /// large repository that scan is the background work competing with
    /// terminal input (upstream #4705 / PR #5665).
    @Test func sidebarReadSkipsIndexAndTrackedFileScans() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("tracked.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let trackedPath = fixture.root.appendingPathComponent("tracked.txt").path

        // Guard against a vacuous assertion: the exact path really does stat
        // the tracked working-tree file through the injected reader.
        let fullReader = CountingGitFileStatusReader()
        let full = await GitMetadataService(fileStatusReader: fullReader).workspaceMetadata(
            for: fixture.root.path,
            trackedPathEventGeneration: nil,
            options: .full
        )
        #expect(full.isRepository)
        #expect(fullReader.callCount(atPath: trackedPath) > 0)

        let sidebarReader = CountingGitFileStatusReader()
        let sidebar = await GitMetadataService(fileStatusReader: sidebarReader).workspaceMetadata(
            for: fixture.root.path,
            trackedPathEventGeneration: nil,
            options: .sidebar
        )
        #expect(sidebar.isRepository)
        // Branch and HEAD are still exact, which is all a routine sidebar
        // probe needs.
        #expect(sidebar.branch == full.branch)
        #expect(sidebar.headSignature == full.headSignature)
        // Dirty state and index signatures are deliberately unavailable.
        #expect(sidebar.isDirty == false)
        #expect(sidebar.indexSignature == nil)
        #expect(sidebar.indexContentSignature == nil)
        // No filesystem status reads at all: no index parse, no per-entry
        // lstat scan, no second reference reconciliation probe.
        #expect(sidebarReader.totalCallCount == 0)
    }

    @Test func readOptionsKeepFullAsTheExactDefault() {
        #expect(GitMetadataReadOptions.full.checksWorkingTreeDirty)
        #expect(!GitMetadataReadOptions.sidebar.checksWorkingTreeDirty)
        #expect(GitMetadataReadOptions.full != GitMetadataReadOptions.sidebar)
    }
}
