import CmuxBrowser
import Foundation
import WebKit

/// Keeps the Force Dark engine registered on the web views cmux browses with.
///
/// WebKit can only remove user scripts all at once, so the scripts created here
/// are tracked in a weak set: removing one re-adds every other script in order
/// and leaves the controller's own scripts (form state, automation, ...) alone.
@MainActor
enum BrowserForceDarkUserScript {
    private static let installedScripts = NSHashTable<WKUserScript>.weakObjects()

    /// Registers the engine for `url`, or removes it when the policy skips the
    /// page. A page that already carries an engine with the same policy keeps
    /// it, so navigations do not churn the controller.
    static func sync(
        policy: BrowserForceDarkPolicy,
        url: URL?,
        in controller: WKUserContentController
    ) {
        let target = BrowserForceDarkRuntime.makeUserScript(policy: policy, url: url)
        if let installed = controller.userScripts.first(where: installedScripts.contains) {
            if let target, installed.source == target.source { return }
            remove(installed, from: controller)
        }
        guard let target else { return }
        installedScripts.add(target)
        controller.addUserScript(target)
    }

    /// Removes the engine from the controller, when it is registered there.
    static func remove(from controller: WKUserContentController) {
        guard let installed = controller.userScripts.first(where: installedScripts.contains) else {
            return
        }
        remove(installed, from: controller)
    }

    /// Re-applies the engine to the document that is already loaded. The
    /// document-start script only reaches the next document.
    static func syncLoadedDocument(
        policy: BrowserForceDarkPolicy,
        url: URL?,
        in webView: WKWebView
    ) {
        if let source = BrowserForceDarkRuntime.bootstrapSource(policy: policy, url: url) {
            webView.evaluateJavaScript(source, completionHandler: nil)
        } else {
            webView.evaluateJavaScript(
                BrowserForceDarkRuntime.disableScript,
                completionHandler: nil
            )
        }
    }

    private static func remove(_ script: WKUserScript, from controller: WKUserContentController) {
        // `userScripts` is a live view of the controller's list; copy it first.
        let scripts = controller.userScripts.map { $0 }
        guard scripts.contains(where: { $0 === script }) else { return }
        controller.removeAllUserScripts()
        for remaining in scripts where remaining !== script {
            controller.addUserScript(remaining)
        }
    }
}

extension BrowserPanel {
    /// The Force Dark policy for the selected theme and the exception list.
    var forceDarkPolicy: BrowserForceDarkPolicy {
        BrowserForceDarkPolicy(
            isEnabled: currentBrowserThemeMode == .forceDark,
            excludedHosts: BrowserForceDarkSettings.excludedHosts()
        )
    }

    /// The URL the policy is evaluated against.
    private var forceDarkPageURL: URL? {
        webView.url ?? currentURL
    }

    /// Registers or removes the document-start engine for `url` (defaults to the
    /// page the web view is on). Called from every theme application path —
    /// creation, web view replacement, WebContent crash recovery — and from each
    /// main-frame navigation.
    func syncForceDarkUserScript(for url: URL? = nil) {
        BrowserForceDarkUserScript.sync(
            policy: forceDarkPolicy,
            url: url ?? forceDarkPageURL,
            in: webView.configuration.userContentController
        )
    }

    /// Switches the already-loaded document between forced dark and its own
    /// appearance. The document-start script only covers later documents.
    func applyForceDarkToLoadedDocument() {
        BrowserForceDarkUserScript.syncLoadedDocument(
            policy: forceDarkPolicy,
            url: forceDarkPageURL,
            in: webView
        )
    }

    /// Whether the current site keeps its own appearance under Force Dark.
    var isCurrentSiteForceDarkExcluded: Bool {
        guard let host = forceDarkPageURL?.host, !host.isEmpty else { return false }
        return BrowserForceDarkSettings.isHostExcluded(host)
    }

    /// Whether the page in front of the user is a site an exception can cover.
    var canToggleForceDarkSiteException: Bool {
        guard let url = forceDarkPageURL, let scheme = url.scheme?.lowercased() else {
            return false
        }
        guard scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// Adds or removes the current site's Force Dark exception.
    func setCurrentSiteForceDarkExcluded(_ excluded: Bool) {
        guard let host = forceDarkPageURL?.host, !host.isEmpty else { return }
        BrowserForceDarkSettings.setHostExcluded(host, excluded: excluded)
    }

    /// Part of every theme application: installs the exception observer once and
    /// re-registers the engine for the page in front of the user.
    func applyForceDarkModeIfNeeded() {
        if forceDarkExcludedHostsObserver == nil {
            forceDarkExcludedHostsObserver = NotificationCenter.default.addObserver(
                forName: BrowserForceDarkSettings.excludedHostsDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self, Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    self.applyForceDarkAfterExceptionChange()
                }
            }
        }
        syncForceDarkUserScript()
    }

    /// A site exception added in another tab changes this page too.
    private func applyForceDarkAfterExceptionChange() {
        syncForceDarkUserScript()
        applyForceDarkToLoadedDocument()
        for controller in popupControllers {
            controller.syncForceDarkMode()
            controller.applyForceDarkToLoadedDocuments()
        }
    }
}

extension BrowserPopupWindowController {
    /// The Force Dark policy for this popup's theme and the exception list.
    private var forceDarkPolicy: BrowserForceDarkPolicy {
        BrowserForceDarkPolicy(
            isEnabled: browserThemeMode == .forceDark,
            excludedHosts: BrowserForceDarkSettings.excludedHosts()
        )
    }

    /// Registers or removes the document-start engine for this popup's web view
    /// and every nested popup, and switches the loaded documents over.
    func syncForceDarkMode() {
        let policy = forceDarkPolicy
        for webView in webViewsIncludingChildPopups {
            BrowserForceDarkUserScript.sync(
                policy: policy,
                url: webView.url,
                in: webView.configuration.userContentController
            )
        }
    }

    /// Switches the already-loaded documents over; called when the theme or the
    /// exception list changes while a popup is open.
    func applyForceDarkToLoadedDocuments() {
        let policy = forceDarkPolicy
        for webView in webViewsIncludingChildPopups {
            BrowserForceDarkUserScript.syncLoadedDocument(
                policy: policy,
                url: webView.url,
                in: webView
            )
        }
    }
}
