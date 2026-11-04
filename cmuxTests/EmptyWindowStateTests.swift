import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A @MainActor Swift Testing body already runs inside a main queue block, so
/// the main queue cannot drain until the test returns and every
/// `drainMainQueue` call spins the run loop until its timeout. Spin briefly.
private let emptyWindowMainQueueSpin: TimeInterval = 0.1

/// Contract for https://github.com/xhqing/cmux/issues/2.
///
/// Closing the last workspace — through the tab-strip X, Cmd+W, middle click,
/// an explicit workspace close, or a child-process exit — must leave the
/// window open in an empty state (no workspaces, no tabs, `selectedTabId`
/// nil) instead of closing the window and quitting the app. Only a
/// window-level close (red button, Close Window, Cmd+Q) may quit.
///
/// Restoring an empty session snapshot must not fabricate a fallback
/// workspace, and the empty window must be able to create its first
/// workspace through the sidebar "+" / command-palette path
/// (`addWorkspaceIfActive`). "Keep Workspace Open"
/// (`closeWorkspaceOnLastSurfaceShortcut == false`) keeps its existing
/// behavior: the workspace survives and gets a replacement terminal.
@MainActor
@Suite("Empty window state after closing the last workspace", .serialized, .exclusiveAppContext)
struct EmptyWindowStateTests {
    private static let closeWorkspaceOnLastSurfaceKey = "closeWorkspaceOnLastSurfaceShortcut"

    private func drainMainQueueForCloseTest(timeout: TimeInterval = emptyWindowMainQueueSpin) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
    }

    private func withManager(
        closeWorkspaceOnLastSurface: Bool? = nil,
        warnBeforeClosingWorkspace: Bool? = nil,
        confirmCloseRunningProcess: Bool? = nil,
        createInitialWorkspace: Bool = true,
        run: (TabManager) throws -> Void
    ) throws {
        let suiteName = "EmptyWindowStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        if let closeWorkspaceOnLastSurface {
            defaults.set(closeWorkspaceOnLastSurface, forKey: Self.closeWorkspaceOnLastSurfaceKey)
        }
        let catalog = AppCatalogSection()
        if let warnBeforeClosingWorkspace {
            defaults.set(
                warnBeforeClosingWorkspace,
                forKey: catalog.warnBeforeClosingWorkspace.userDefaultsKey
            )
        }
        if let confirmCloseRunningProcess {
            defaults.set(
                confirmCloseRunningProcess,
                forKey: catalog.confirmCloseRunningProcess.userDefaultsKey
            )
        }
        // The tab-strip X warning is opt-in (default off); pin it off so the
        // assertions observe the workspace-emptying contract, not the warning.
        defaults.set(false, forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey)

        ClosedItemHistoryStore.shared.removeAll()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            createInitialWorkspace: createInitialWorkspace,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        defer {
            manager.closeWorkspacesForTesting()
            ClosedItemHistoryStore.shared.removeAll()
        }
        try run(manager)
    }

    /// Installs a throwaway `AppDelegate` so the close paths' window-close
    /// requests land on a delegate this test owns instead of the host app.
    private func withThrowawayAppDelegate(_ run: (AppDelegate) throws -> Void) throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }
        try run(appDelegate)
    }

    // MARK: - New contract

    @Test("Closing the last workspace through each close path empties the window")
    func lastWorkspaceClosePathsEmptyTheWindow() throws {
        try withThrowawayAppDelegate { appDelegate in
            #if DEBUG
            var windowCloseRequests = 0
            appDelegate.closeMainWindowContainingTabIdObserverForTesting = { _, _ in
                windowCloseRequests += 1
            }
            defer { appDelegate.closeMainWindowContainingTabIdObserverForTesting = nil }
            #endif

            let closePaths: [(String, (TabManager, Workspace) -> Void)] = [
                ("closeWorkspaceFromTabCloseButton", { manager, workspace in
                    _ = manager.closeWorkspaceFromTabCloseButton(workspace)
                }),
                ("closeWorkspaceFromCloseTabGesture", { manager, workspace in
                    _ = manager.closeWorkspaceFromCloseTabGesture(workspace)
                }),
                ("closeWorkspacesWithConfirmation", { manager, workspace in
                    manager.closeWorkspacesWithConfirmation([workspace.id], allowPinned: true)
                }),
            ]

            for (name, close) in closePaths {
                try withManager { manager in
                    manager.confirmCloseHandler = { _, _, _ in true }
                    let workspace = try #require(manager.tabs.first)
                    #expect(manager.tabs.count == 1)

                    close(manager, workspace)
                    drainMainQueueForCloseTest()

                    #expect(
                        manager.tabs.isEmpty,
                        Comment(rawValue: "\(name) must empty the window instead of closing it")
                    )
                    #expect(
                        manager.selectedTabId == nil,
                        Comment(rawValue: "\(name) must clear the selection")
                    )
                    #expect(
                        !manager.isFinalizedForWindowClose,
                        Comment(rawValue: "\(name) must keep the window open")
                    )
                    #if DEBUG
                    #expect(
                        windowCloseRequests == 0,
                        Comment(rawValue: "\(name) must not request a window close")
                    )
                    #endif
                }
            }
        }
    }

    @Test("Tab-strip X on the last surface empties the window without a workspace prompt")
    func tabStripCloseButtonOnLastSurfaceEmptiesTheWindow() throws {
        try withThrowawayAppDelegate { appDelegate in
            #if DEBUG
            var windowCloseRequests = 0
            appDelegate.closeMainWindowContainingTabIdObserverForTesting = { _, _ in
                windowCloseRequests += 1
            }
            defer { appDelegate.closeMainWindowContainingTabIdObserverForTesting = nil }
            #endif

            try withManager { manager in
                var prompts: [String] = []
                manager.confirmCloseHandler = { title, _, _ in
                    prompts.append(title)
                    return true
                }
                let workspace = try #require(manager.tabs.first)
                let panelId = try #require(workspace.focusedPanelId)
                let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId))

                workspace.markTabCloseButtonClose(surfaceId: surfaceId)
                _ = workspace.closePanel(panelId)
                drainMainQueueForCloseTest()

                #expect(manager.tabs.isEmpty, "The workspace goes away with its last tab")
                #expect(manager.selectedTabId == nil)
                #expect(prompts.isEmpty, "Closing the tab must not ask a workspace/window confirmation")
                #expect(!manager.isFinalizedForWindowClose)
                #if DEBUG
                #expect(windowCloseRequests == 0)
                #endif
            }
        }
    }

    @Test("Running-process protection still prompts on the tab-strip X of the last surface")
    func tabStripCloseOfLastSurfaceKeepsRunningProcessPrompt() throws {
        try withThrowawayAppDelegate { appDelegate in
            #if DEBUG
            var windowCloseRequests = 0
            appDelegate.closeMainWindowContainingTabIdObserverForTesting = { _, _ in
                windowCloseRequests += 1
            }
            defer { appDelegate.closeMainWindowContainingTabIdObserverForTesting = nil }
            #endif

            try withManager(confirmCloseRunningProcess: true) { manager in
                let closeTabTitle = String(
                    localized: "dialog.closeTab.title",
                    defaultValue: "Close tab?"
                )
                var prompts: [String] = []
                var acceptsPrompt = false
                manager.confirmCloseHandler = { title, _, _ in
                    prompts.append(title)
                    return acceptsPrompt
                }
                let workspace = try #require(manager.tabs.first)
                let panelId = try #require(workspace.focusedPanelId)
                let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId))
                let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
                terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)

                // Cancel: the tab and its workspace must stay untouched.
                workspace.markTabCloseButtonClose(surfaceId: surfaceId)
                _ = workspace.closePanel(panelId)
                drainMainQueueForCloseTest()

                #expect(prompts == [closeTabTitle], "A live process must still ask before the last tab closes")
                #expect(manager.tabs.map(\.id) == [workspace.id])
                #expect(manager.selectedTabId == workspace.id)
                #expect(workspace.panels[panelId] != nil)

                // Accept: the last tab closes, the workspace goes with it, and
                // the window stays open (Issue #2).
                acceptsPrompt = true
                workspace.markTabCloseButtonClose(surfaceId: surfaceId)
                _ = workspace.closePanel(panelId)
                drainMainQueueForCloseTest()

                #expect(manager.tabs.isEmpty)
                #expect(manager.selectedTabId == nil)
                #expect(!manager.isFinalizedForWindowClose)
                #if DEBUG
                #expect(windowCloseRequests == 0)
                #endif
            }
        }
    }

    @Test("Middle-click on the last surface empties the window")
    func middleClickOnLastSurfaceEmptiesTheWindow() throws {
        try withManager { manager in
            manager.confirmCloseHandler = { _, _, _ in true }
            let workspace = try #require(manager.tabs.first)
            let panelId = try #require(workspace.focusedPanelId)
            let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId))

            workspace.markTabStripMiddleClickClose(surfaceId: surfaceId)
            _ = workspace.closePanel(panelId)
            drainMainQueueForCloseTest()

            #expect(manager.tabs.isEmpty)
            #expect(manager.selectedTabId == nil)
            #expect(!manager.isFinalizedForWindowClose)
        }
    }

    @Test("Child exit of the only panel empties the window")
    func childExitOfLastPanelEmptiesTheWindow() throws {
        try withThrowawayAppDelegate { appDelegate in
            #if DEBUG
            var windowCloseRequests = 0
            appDelegate.closeMainWindowContainingTabIdObserverForTesting = { _, _ in
                windowCloseRequests += 1
            }
            defer { appDelegate.closeMainWindowContainingTabIdObserverForTesting = nil }
            #endif

            try withManager { manager in
                let workspace = try #require(manager.tabs.first)
                let panelId = try #require(workspace.focusedPanelId)

                manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panelId)
                drainMainQueueForCloseTest()

                #expect(manager.tabs.isEmpty)
                #expect(manager.selectedTabId == nil)
                #expect(!manager.isFinalizedForWindowClose)
                #if DEBUG
                #expect(windowCloseRequests == 0)
                #endif
            }
        }
    }

    @Test("Restoring an empty session snapshot leaves the window empty")
    func emptySessionSnapshotRestoresAnEmptyWindow() throws {
        try withManager(createInitialWorkspace: false) { manager in
            let emptySnapshot = SessionTabManagerSnapshot(
                selectedWorkspaceIndex: nil,
                workspaces: []
            )

            manager.restoreSessionSnapshot(emptySnapshot)

            #expect(manager.tabs.isEmpty, "No fallback workspace may be fabricated")
            #expect(manager.selectedTabId == nil)
        }
    }

    @Test("An empty window can create its first workspace")
    func emptyWindowCreatesItsFirstWorkspace() throws {
        try withManager(createInitialWorkspace: false) { manager in
            #expect(manager.tabs.isEmpty)

            let created = try #require(manager.addWorkspaceIfActive())

            #expect(manager.tabs.count == 1)
            #expect(manager.tabs.first?.id == created.id)
            #expect(manager.selectedTabId == created.id)
        }
    }

    @Test("A manager created for a plain launch starts empty and stays empty")
    func managerWithoutInitialWorkspaceStartsEmptyForPlainLaunch() throws {
        try withManager(createInitialWorkspace: false) { manager in
            #expect(manager.tabs.isEmpty, "A plain launch must not fabricate a workspace")
            #expect(manager.selectedTabId == nil)
            #expect(
                manager.hasEmptiedAllWorkspaces,
                "Startup recovery (#399) must not refill an intentionally empty window"
            )
        }
    }

    @Test("A plain New Window starts as an empty window")
    func plainMainWindowStartsEmpty() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeMainWindowForEmptyStateTest(appDelegate, windowId: windowId) }

        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        #expect(manager.tabs.isEmpty, "A plain New Window must not fabricate a workspace")
        #expect(manager.selectedTabId == nil)
        #expect(
            manager.hasEmptiedAllWorkspaces,
            "Startup recovery (#399) must not refill an intentionally empty window"
        )
    }

    @Test("An explicit working directory still creates its initial workspace")
    func explicitWorkingDirectoryCreatesTheInitialWorkspace() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow(
            initialWorkingDirectory: NSTemporaryDirectory()
        )
        defer { closeMainWindowForEmptyStateTest(appDelegate, windowId: windowId) }

        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        #expect(
            manager.tabs.count == 1,
            "An explicitly requested working directory must keep its initial workspace"
        )
        #expect(manager.selectedTabId == manager.tabs.first?.id)
    }

    @Test("An explicit terminal input still creates its initial workspace")
    func explicitTerminalInputCreatesTheInitialWorkspace() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow(initialTerminalInput: "echo hi")
        defer { closeMainWindowForEmptyStateTest(appDelegate, windowId: windowId) }

        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        #expect(
            manager.tabs.count == 1,
            "An explicitly requested terminal input must keep its initial workspace"
        )
        #expect(manager.selectedTabId == manager.tabs.first?.id)
    }

    /// Retires a main window created by ``createMainWindow`` and waits for its
    /// `MainWindowContext` to go away. A half-closed window would otherwise
    /// leak its manager and workspaces into the next test in this suite.
    private func closeMainWindowForEmptyStateTest(_ appDelegate: AppDelegate, windowId: UUID) {
        guard let window = appDelegate.windowForMainWindowId(windowId) else { return }
        let previousConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              appDelegate.mainWindowContexts.values.contains(where: { $0.windowId == windowId }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Regressions

    @Test("Closing one of several workspaces keeps the survivors and their selection")
    func closingOneOfSeveralWorkspacesKeepsTheSurvivors() throws {
        try withManager { manager in
            manager.confirmCloseHandler = { _, _, _ in true }
            let first = try #require(manager.tabs.first)
            let second = manager.addWorkspace()
            let third = manager.addWorkspace()
            manager.selectWorkspace(second)

            manager.closeWorkspaceFromTabCloseButton(first)
            drainMainQueueForCloseTest()

            #expect(manager.tabs.map(\.id) == [second.id, third.id])
            #expect(manager.selectedTabId == second.id)
        }
    }

    @Test("Keep Workspace Open keeps the last workspace with a replacement terminal")
    func keepWorkspaceOpenPreferenceKeepsTheLastWorkspace() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            manager.confirmCloseHandler = { _, _, _ in true }
            let workspace = try #require(manager.tabs.first)
            let panelId = try #require(workspace.focusedPanelId)
            let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId))

            var didClose = false
            workspace.withClosedPanelHistorySuppressed {
                workspace.markTabCloseButtonClose(surfaceId: surfaceId)
                didClose = workspace.closePanel(panelId)
            }
            #expect(didClose)
            drainMainQueueForCloseTest()
            drainMainQueueForCloseTest()

            #expect(manager.tabs.map(\.id) == [workspace.id], "The workspace must survive")
            #expect(manager.selectedTabId == workspace.id)
            #expect(workspace.panels[panelId] == nil)
            #expect(workspace.panels.count == 1, "A replacement terminal keeps the workspace usable")
        }
    }

    @Test("Sidebar close of the last workspace empties the window without quitting")
    func sidebarCloseOfLastWorkspaceEmptiesTheWindow() throws {
        try withThrowawayAppDelegate { appDelegate in
            #if DEBUG
            var windowCloseRequests = 0
            appDelegate.closeMainWindowContainingTabIdObserverForTesting = { _, _ in
                windowCloseRequests += 1
            }
            defer { appDelegate.closeMainWindowContainingTabIdObserverForTesting = nil }
            #endif

            try withManager { manager in
                var prompts: [String] = []
                manager.confirmCloseHandler = { title, _, _ in
                    prompts.append(title)
                    return true
                }
                let workspace = try #require(manager.tabs.first)

                // A clean workspace closes without a dialog under the fork's
                // default running-process policy (P1); the workspace only keeps
                // a prompt when something would actually be lost.
                #expect(manager.closeWorkspaceWithConfirmation(workspace))
                drainMainQueueForCloseTest()

                #expect(prompts.isEmpty, "A clean workspace close does not ask")
                #expect(manager.tabs.isEmpty)
                #expect(manager.selectedTabId == nil)
                #expect(!manager.isFinalizedForWindowClose, "The sidebar close must keep the window")
                #if DEBUG
                #expect(windowCloseRequests == 0)
                #endif
            }
        }
    }

    @Test("Pinned last workspace still uses the pinned-close confirmation")
    func pinnedLastWorkspaceStillUsesPinnedConfirmation() throws {
        try withManager { manager in
            let pinnedWorkspaceTitle = String(
                localized: "dialog.closePinnedWorkspace.title",
                defaultValue: "Close pinned workspace?"
            )
            var prompts: [String] = []
            manager.confirmCloseHandler = { title, _, _ in
                prompts.append(title)
                return false
            }
            let workspace = try #require(manager.tabs.first)
            manager.setPinned(workspace, pinned: true)

            #expect(manager.closeWorkspaceWithConfirmation(workspace) == false)
            #expect(prompts == [pinnedWorkspaceTitle])
            #expect(manager.tabs.map(\.id) == [workspace.id])
        }
    }

    @Test("Running-process protection still prompts when the setting is enabled")
    func runningProcessProtectionStillPromptsWhenEnabled() throws {
        try withManager(
            warnBeforeClosingWorkspace: false,
            confirmCloseRunningProcess: true
        ) { manager in
            let closeWorkspaceTitle = String(
                localized: "dialog.closeWorkspace.title",
                defaultValue: "Close workspace?"
            )
            var prompts: [String] = []
            manager.confirmCloseHandler = { title, _, _ in
                prompts.append(title)
                return false
            }
            let workspace = try #require(manager.tabs.first)
            let panelId = try #require(workspace.focusedPanelId)
            workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

            #expect(manager.closeWorkspaceWithConfirmation(workspace) == false)
            #expect(prompts == [closeWorkspaceTitle], "A live process must still warn")
            #expect(manager.tabs.map(\.id) == [workspace.id])
        }
    }
}
