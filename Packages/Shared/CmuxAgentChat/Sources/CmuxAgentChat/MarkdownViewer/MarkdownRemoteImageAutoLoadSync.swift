/// Tracks how the markdown viewer's remote-image auto-load flag is
/// synchronized with the page.
///
/// The flag lives in the page's JavaScript, and that page does not exist until
/// the shell document finishes loading. A push attempted before then (`about:blank`
/// during `makeNSView`, or an in-flight `loadHTMLString`) is silently dropped by
/// `evaluateJavaScript`; if the host records it as applied anyway, `didFinish`
/// has nothing left to send and the page stays on the shell's manual default.
///
/// That ordering is exactly the r15 regression this type prevents: a value is
/// only remembered as delivered once the shell is ready, and `didFinish` always
/// returns a value to push so a reload can never skip the re-injection.
///
/// The type is a plain value so the ordering rules can be tested without a
/// WebView. The app's `cmuxTests` target is not part of PR CI, but changes under
/// this package are built and tested by `scripts/check-swift-packages.py`.
public struct MarkdownRemoteImageAutoLoadSync: Equatable, Sendable {
    /// The value the host wants the current page to use.
    public private(set) var requested: Bool
    /// Whether the current shell document has finished loading.
    public private(set) var shellIsReady: Bool
    /// The value the current shell document has received, if any.
    public private(set) var applied: Bool?

    public init(initialValue: Bool) {
        requested = initialValue
        shellIsReady = false
        applied = nil
    }

    /// Records a new setting value. It is not marked as applied: call
    /// ``pendingPush()`` to deliver it while the shell is ready, otherwise the
    /// next ``shellLoadFinished()`` will.
    public mutating func request(_ enabled: Bool) {
        requested = enabled
    }

    /// Marks the start of a shell (re)load. The page-side flag disappeared with
    /// the old document, so nothing counts as applied until the new document
    /// finishes loading.
    public mutating func shellLoadStarted() {
        shellIsReady = false
        applied = nil
    }

    /// Marks the shell as loaded and returns the value that must be pushed now.
    ///
    /// `didFinish` is the one place that always pushes: an earlier attempt may
    /// have looked successful while the page was still `about:blank`, and a
    /// reload drops the page state entirely. The value is recorded as applied
    /// because the caller delivers it immediately after this call.
    public mutating func shellLoadFinished() -> Bool {
        shellIsReady = true
        applied = requested
        return requested
    }

    /// Returns the value to push for an ordinary update, or `nil` when the shell
    /// is not ready yet or the current document already has this value.
    public mutating func pendingPush() -> Bool? {
        guard shellIsReady, applied != requested else { return nil }
        applied = requested
        return requested
    }
}
