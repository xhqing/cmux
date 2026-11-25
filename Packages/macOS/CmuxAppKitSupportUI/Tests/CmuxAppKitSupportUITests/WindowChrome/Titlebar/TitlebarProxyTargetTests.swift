import Testing

@testable import CmuxAppKitSupportUI

@Suite struct TitlebarProxyTargetTests {
    @Test func focusedFileWinsOverTheWorkspaceDirectory() {
        let target = TitlebarProxyTarget.resolve(
            focusedDirectory: "/Users/me/Developer/notes",
            focusedFile: "/Users/me/Developer/notes/plan.md"
        )

        #expect(target == .file("/Users/me/Developer/notes/plan.md"))
        #expect(target?.path == "/Users/me/Developer/notes/plan.md")
        #expect(target?.menuDirectory == "/Users/me/Developer/notes")
        #expect(target?.isDirectory == false)
    }

    @Test func directoryFocusKeepsTheFolderTarget() {
        let target = TitlebarProxyTarget.resolve(
            focusedDirectory: "/Users/me/Developer/notes",
            focusedFile: nil
        )

        #expect(target == .directory("/Users/me/Developer/notes"))
        #expect(target?.path == "/Users/me/Developer/notes")
        #expect(target?.menuDirectory == "/Users/me/Developer/notes")
        #expect(target?.isDirectory == true)
    }

    @Test func missingPathsCarveNoProxyIcon() {
        #expect(TitlebarProxyTarget.resolve(focusedDirectory: nil, focusedFile: nil) == nil)
    }

    @Test func blankPathsAreTreatedAsMissing() {
        let target = TitlebarProxyTarget.resolve(
            focusedDirectory: "   ",
            focusedFile: "\n/"
        )

        #expect(target == .file("/"))
        #expect(target?.menuDirectory == "/")
        #expect(TitlebarProxyTarget.resolve(focusedDirectory: "", focusedFile: "  ") == nil)
    }

    @Test("文件目标的路径菜单列的是它所在的文件夹，不是文件本身")
    func fileMenuDirectoryIsTheParentFolder() {
        let target = TitlebarProxyTarget.file("/Users/me/notes/deep/plan.md")

        #expect(target.menuDirectory == "/Users/me/notes/deep")
        #expect(target.path == "/Users/me/notes/deep/plan.md")
    }
}
