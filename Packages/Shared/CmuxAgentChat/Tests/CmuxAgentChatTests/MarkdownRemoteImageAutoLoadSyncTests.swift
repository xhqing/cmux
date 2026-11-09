import Testing
@testable import CmuxAgentChat

@Suite struct MarkdownRemoteImageAutoLoadSyncTests {
    /// r15 regression: makeNSView and the first updateNSView both push `true`
    /// while the page is still `about:blank` / the shell is still loading. Those
    /// attempts must not count, and didFinish must still deliver the value.
    @Test func pushesBeforeTheShellLoadsDoNotHideTheDidFinishPush() {
        var sync = MarkdownRemoteImageAutoLoadSync(initialValue: false)

        // makeNSView: the WebView is on about:blank.
        sync.request(true)
        #expect(sync.pendingPush() == nil)
        #expect(sync.applied == nil)

        // loadShell has started; updateNSView races the in-flight load.
        sync.shellLoadStarted()
        #expect(sync.pendingPush() == nil)
        #expect(sync.applied == nil)

        // didFinish must deliver even though two pushes were attempted first.
        #expect(sync.shellLoadFinished() == true)
        #expect(sync.applied == true)

        // Ordinary layout passes must not repeat the sweep.
        #expect(sync.pendingPush() == nil)
    }

    @Test func aShellReloadForcesTheSameValueAgain() {
        var sync = MarkdownRemoteImageAutoLoadSync(initialValue: true)
        sync.shellLoadStarted()
        #expect(sync.shellLoadFinished() == true)
        #expect(sync.pendingPush() == nil)

        // Crash recovery / pane re-entry loads a fresh document with the same
        // setting; the page-side flag is gone, so didFinish must push again.
        sync.shellLoadStarted()
        #expect(sync.pendingPush() == nil)
        #expect(sync.shellLoadFinished() == true)
    }

    @Test func changesAfterTheShellLoadsPushExactlyOnce() {
        var sync = MarkdownRemoteImageAutoLoadSync(initialValue: false)
        sync.shellLoadStarted()
        #expect(sync.shellLoadFinished() == false)
        #expect(sync.pendingPush() == nil)

        sync.request(true)
        #expect(sync.pendingPush() == true)
        #expect(sync.pendingPush() == nil)

        // Turning the setting back off must reach the page too (manual flow).
        sync.request(false)
        #expect(sync.pendingPush() == false)
        #expect(sync.pendingPush() == nil)
    }

    @Test func aChangeBeforeTheShellLoadsIsDeliveredByDidFinish() {
        var sync = MarkdownRemoteImageAutoLoadSync(initialValue: false)
        sync.request(true)
        sync.shellLoadStarted()
        sync.request(false)
        sync.request(true)

        #expect(sync.pendingPush() == nil)
        #expect(sync.shellLoadFinished() == true)
        #expect(sync.pendingPush() == nil)
    }
}
