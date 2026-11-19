// Behavioral tests for the markdown panel's in-place editor.
//
// The editor is a page-side JS layer (`Resources/markdown-viewer/markdown-editor.js`)
// loaded through `shell.html`, so the assertions here run the real page in an
// offscreen WKWebView: load the shell, render markdown, activate the editing
// layer, dispatch clicks, type through `execCommand('insertText')`, and read the
// committed document back through `CmuxMarkdownEditor.flush()`.
//
// The contract under test (the reason the file exists):
//   1. Activating a block must not paint an editor chrome of any kind — no
//      overlay element, no textarea, no “保存 / Esc” hint — and must not move
//      the block by a single point.
//   2. The caret must land where the user clicked, and typing must land there
//      too, so editing feels like VS Code's markdown editor.
//   3. Only the block the user actually edited may change in the committed
//      markdown; every other block stays byte-identical.
//   4. The editable surface lives in the document flow, so scrolling moves the
//      text with the page (no drifting floating box).
//   5. Blocks the editor cannot round-trip faithfully (math, diagrams, images,
//      tables) must never be corrupted by an edit.
//
// Run: swift scripts/tests/test_markdown_editor_inplace.swift
// Exit code 0 = every check passed.

import AppKit
import Foundation
import WebKit

// MARK: - Locations

let scriptURL = URL(fileURLWithPath: #filePath)
let repositoryRoot = scriptURL
    .deletingLastPathComponent() // scripts/tests
    .deletingLastPathComponent() // scripts
    .deletingLastPathComponent() // repository root
let viewerResources = repositoryRoot.appendingPathComponent("Resources/markdown-viewer")

func asset(_ name: String, _ ext: String) -> String {
    let url = viewerResources.appendingPathComponent("\(name).\(ext)")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write(Data("missing asset: \(url.path)\n".utf8))
        exit(2)
    }
    return text
}

func shellHTML() -> String {
    var html = asset("shell", "html")
    let substitutions: [(String, String)] = [
        ("{{githubMarkdownCSS}}", asset("github-markdown", "css")),
        ("{{highlightLightCSS}}", asset("highlight-github", "css")),
        ("{{highlightDarkCSS}}", asset("highlight-github-dark", "css")),
        ("{{markedJS}}", asset("marked.min", "js")),
        ("{{highlightJS}}", asset("highlight.min", "js")),
        ("{{viewerNavigationJS}}", asset("viewer-navigation", "js")),
        ("{{markdownSanitizerJS}}", asset("markdown-sanitizer", "js")),
        ("{{markdownEditorJS}}", asset("markdown-editor", "js")),
        ("{{localizedStringsJSON}}", "{}"),
    ]
    for (needle, value) in substitutions {
        html = html.replacingOccurrences(of: needle, with: value)
    }
    return html
}

// MARK: - Offscreen web view

final class ShellLoadObserver: NSObject, WKNavigationDelegate {
    var didFinish = false
    var failure: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error
        didFinish = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error
        didFinish = true
    }
}

/// Serves the lazily requested diagram / math libraries the way the host app
/// does (`MarkdownWebRenderer.handleLibRequest`), so blocks that depend on them
/// render in the harness instead of falling back to "bridge unavailable".
final class LibBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private var requested: Set<String> = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let lib = body["lib"] as? String else { return }
        guard !requested.contains(lib) else { return }
        requested.insert(lib)

        var source = ""
        switch lib {
        case "mermaid":
            source = asset("mermaid.min", "js")
        case "vega-lite":
            source = [asset("vega", "min.js"), asset("vega-lite", "min.js"), asset("vega-embed", "min.js")]
                .joined(separator: "\n;")
        case "katex":
            let css = asset("katex-fonts", "min.css")
            let cssLiteral = (try? JSONSerialization.data(withJSONObject: [css]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            source = """
            (function(css){
              if (!document.getElementById('cmux-katex-css')) {
                var styleEl = document.createElement('style');
                styleEl.id = 'cmux-katex-css';
                styleEl.textContent = css;
                (document.head || document.documentElement).appendChild(styleEl);
              }
            })(\(cssLiteral)[0]);
            """ + "\n;" + asset("katex", "min.js")
        default:
            return
        }
        guard !source.isEmpty, let webView else { return }
        webView.evaluateJavaScript(source + "\n;window.__cmuxLibLoaded && window.__cmuxLibLoaded('" + lib + "');", completionHandler: nil)
    }
}

func pumpRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

final class Page {
    let webView: WKWebView
    private let window: NSWindow
    private let libBridge = LibBridge()

    init() throws {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 720)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(libBridge, name: "cmuxLib")
        webView = WKWebView(frame: frame, configuration: configuration)
        libBridge.webView = webView
        let observer = ShellLoadObserver()
        webView.navigationDelegate = observer
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()

        let base = URL(fileURLWithPath: viewerResources.appendingPathComponent("placeholder.md").path)
        webView.loadHTMLString(shellHTML(), baseURL: base)
        var waited = 0.0
        while !observer.didFinish && waited < 20 {
            pumpRunLoop(0.02)
            waited += 0.02
        }
        if let failure = observer.failure {
            throw NSError(domain: "MarkdownEditorHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "shell load failed: \(failure)"])
        }
        guard observer.didFinish else {
            throw NSError(domain: "MarkdownEditorHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "shell load timed out"])
        }
        try installHelpers()
    }

    deinit {
        webView.navigationDelegate = nil
        window.close()
    }

    /// Evaluates JS synchronously, returning the raw bridge value or throwing
    /// the underlying JavaScript error so a broken page fails the run loudly.
    @discardableResult
    func eval(_ script: String) throws -> Any? {
        var value: Any?
        var error: Error?
        var finished = false
        webView.evaluateJavaScript(script) { result, thrown in
            value = result
            error = thrown
            finished = true
        }
        var waited = 0.0
        while !finished && waited < 20 {
            pumpRunLoop(0.02)
            waited += 0.02
        }
        if let error { throw error }
        if !finished {
            throw NSError(domain: "MarkdownEditorHarness", code: 3, userInfo: [NSLocalizedDescriptionKey: "JavaScript timed out: \(script.prefix(120))"])
        }
        return value
    }

    /// Evaluates JS that returns a JSON string and decodes it into a dictionary.
    func json(_ script: String) throws -> [String: Any] {
        let raw = try eval(script)
        guard let text = raw as? String, let data = text.data(using: .utf8) else {
            throw NSError(domain: "MarkdownEditorHarness", code: 4, userInfo: [NSLocalizedDescriptionKey: "expected JSON string, got \(String(describing: raw))"])
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MarkdownEditorHarness", code: 5, userInfo: [NSLocalizedDescriptionKey: "expected JSON object, got \(text.prefix(400))"])
        }
        return object
    }

    func render(_ markdown: String) throws {
        let literal = try jsStringLiteral(markdown)
        try eval("window.__cmuxRenderMarkdown(\(literal)); true")
    }

    func installEditor(locked: Bool = false) throws {
        try eval(
            """
            window.__testPosts = [];
            window.CmuxMarkdownEditor.install({
              contentElement: document.getElementById('content'),
              locked: \(locked ? "true" : "false"),
              postToHost: function(payload) { window.__testPosts.push(payload); }
            });
            document.documentElement.style.scrollBehavior = 'auto';
            true
            """
        )
    }

    func flush() throws -> String {
        let raw = try eval("window.CmuxMarkdownEditor.flush()")
        return (raw as? String) ?? ""
    }

    /// Polls a JS expression until it is truthy or the timeout elapses.
    @discardableResult
    func waitFor(_ script: String, timeout: TimeInterval = 15) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try eval(script) as? NSNumber, value.boolValue { return true }
            if let value = try eval(script) as? Bool, value { return true }
            if let value = try eval(script) as? Int, value != 0 { return true }
            pumpRunLoop(0.1)
        }
        return false
    }

    // MARK: helpers injected into the page

    private func installHelpers() throws {
        let helpers = """
        window.__test = {
          // Point at the caret boundary *before* character `index` of the
          // element's own text: measure the previous character and click just
          // past its right edge, which is where WebKit snaps the caret.
          pointForChar: function(el, index) {
            if (!el) { return null; }
            var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
            var remaining = index, node;
            var previous = null; // { node: Text, offset: int }
            while ((node = walker.nextNode())) {
              var len = node.textContent.length;
              if (len === 0) { continue; }
              if (remaining <= len) {
                previous = remaining > 0
                  ? { node: node, offset: remaining - 1 }
                  : null;
                break;
              }
              previous = { node: node, offset: len - 1 };
              remaining -= len;
            }
            if (!previous) {
              // Caret at the very start: click in the first character's left half.
              var first = el.textContent && el.textContent.length > 0 ? null : null;
              var r0 = document.createRange();
              r0.selectNodeContents(el);
              var rects0 = r0.getClientRects();
              if (!rects0.length) { return null; }
              return { x: rects0[0].left + 1, y: rects0[0].top + rects0[0].height / 2 };
            }
            var range = document.createRange();
            range.setStart(previous.node, previous.offset);
            range.setEnd(previous.node, previous.offset + 1);
            var rect = range.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) { return null; }
            return { x: rect.right - 0.5, y: rect.top + rect.height / 2 };
          },
          elementWithText: function(selector, text) {
            var nodes = Array.prototype.slice.call(document.querySelectorAll(selector));
            for (var i = 0; i < nodes.length; i++) {
              if ((nodes[i].textContent || '').indexOf(text) >= 0) { return nodes[i]; }
            }
            return null;
          },
          blockFor: function(el) {
            return el && el.closest ? el.closest('[data-cmux-block-start]') : null;
          },
          dispatchMouse: function(type, x, y) {
            var target = document.elementFromPoint(x, y) || document.body;
            var event = new MouseEvent(type, {
              bubbles: true, cancelable: true, view: window,
              clientX: x, clientY: y, button: 0, buttons: type === 'mousedown' ? 1 : 0
            });
            target.dispatchEvent(event);
            return target;
          },
          clickAt: function(x, y) {
            window.__test.dispatchMouse('mousedown', x, y);
            window.__test.dispatchMouse('mouseup', x, y);
          },
          clickOutsideContent: function() {
            // The body padding is outside #content: an outside click must commit.
            window.__test.clickAt(3, 3);
          },
          type: function(text) {
            return document.execCommand('insertText', false, text);
          },
          editableBlocks: function() {
            return Array.prototype.slice.call(
              document.querySelectorAll('#content [contenteditable]:not([contenteditable="false"])')
            );
          },
          state: function() {
            var out = {};
            var blocks = window.__test.editableBlocks();
            var block = blocks.length > 0 ? blocks[0] : null;
            out.editableCount = blocks.length;
            var selection = window.getSelection ? window.getSelection() : null;
            out.hasSelection = !!selection && selection.rangeCount > 0;
            out.collapsed = out.hasSelection ? selection.isCollapsed : null;
            out.textareas = document.querySelectorAll('textarea').length;
            out.bodyChildren = document.body.children.length;
            out.bodyText = document.body.innerText || '';
            if (block) {
              var rect = block.getBoundingClientRect();
              out.blockTag = block.tagName;
              out.blockTop = rect.top;
              out.blockLeft = rect.left;
              out.blockHeight = rect.height;
              out.blockPosition = getComputedStyle(block).position;
              out.blockIsDirectChild = !!block.parentElement && block.parentElement.id === 'content';
              out.blockText = block.textContent;
              var all = [block].concat(Array.prototype.slice.call(block.querySelectorAll('*')));
              var floating = 0;
              all.forEach(function(el) {
                var style = getComputedStyle(el);
                if (style.position === 'fixed' || style.position === 'absolute') { floating++; }
              });
              out.floatingDescendants = floating;
              if (out.hasSelection && selection.anchorNode) {
                var anchor = selection.anchorNode;
                out.anchorInsideEditable = block.contains(anchor.nodeType === 3 ? anchor.parentNode : anchor);
                var range = document.createRange();
                range.selectNodeContents(block);
                try {
                  range.setEnd(anchor, selection.anchorOffset);
                  out.caretPrefix = range.toString();
                } catch (e) {
                  out.caretPrefix = null;
                }
              }
            }
            return JSON.stringify(out);
          },
          blockRect: function(el) {
            var rect = el.getBoundingClientRect();
            return JSON.stringify({ top: rect.top, left: rect.left, height: rect.height });
          }
        };
        true
        """
        try eval(helpers)
    }
}

func jsStringLiteral(_ value: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [value])
    let array = String(decoding: data, as: UTF8.self)
    // ["..."] -> "..."
    return String(array.dropFirst().dropLast())
}

// MARK: - Checks

final class Checks {
    private var failures: [String] = []
    private var passed = 0

    func isTrue(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            failures.append("\(name)\(detail().isEmpty ? "" : " — \(detail())")")
        }
    }

    func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        isTrue(name, actual == expected, "got \(actual), expected \(expected)")
    }

    func equalText(_ name: String, _ actual: String, _ expected: String) {
        if actual == expected {
            passed += 1
        } else {
            failures.append("\(name) — got:\n<<<\n\(actual)\n>>>\nexpected:\n<<<\n\(expected)\n>>>")
        }
    }

    func approx(_ name: String, _ actual: Double?, _ expected: Double, tolerance: Double = 1.5) {
        guard let actual else {
            failures.append("\(name) — missing value, expected \(expected)")
            return
        }
        isTrue(name, abs(actual - expected) <= tolerance, "got \(actual), expected \(expected) ±\(tolerance)")
    }

    func report() -> Int32 {
        for failure in failures {
            print("❌ \(failure)")
        }
        print("\(failures.isEmpty ? "✅" : "❌") \(passed) checks passed, \(failures.count) failed")
        return failures.isEmpty ? 0 : 1
    }
}

// MARK: - Helpers

/// Normalizes only trailing whitespace so a serializer's incidental trailing
/// newline does not fail an otherwise exact expectation.
func normalized(_ text: String) -> String {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
    let trimmed = lines.map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
    var joined = trimmed.joined(separator: "\n")
    while joined.hasSuffix("\n\n") { joined.removeLast() }
    if !joined.hasSuffix("\n") { joined += "\n" }
    return joined
}

func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
}

let checks = Checks()
let paragraphSource = "很多人以为这得看模型强弱，弱一点就永远差一口气。"
let paragraphEdited = "很多人以为这得看模型强弱，非常弱一点就永远差一口气。"
let baseDocument = """
# 标题

\(paragraphSource)

下面四步把它证明出来。
"""

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

do {
    // MARK: Scenario 1 — a click paints no chrome and puts the caret under the pointer

    let page = try Page()
    try page.installEditor(locked: false)
    try page.render(baseDocument)

    let before = try page.json(
        """
        (function() {
          var block = window.__test.elementWithText('#content p', '很多人以为');
          return JSON.stringify({ rect: JSON.parse(window.__test.blockRect(block)), bodyChildren: document.body.children.length });
        })()
        """
    )
    let beforeRect = before["rect"] as? [String: Any] ?? [:]
    let beforeTop = number(beforeRect["top"])
    let beforeLeft = number(beforeRect["left"])
    let beforeBodyChildren = before["bodyChildren"] as? Int ?? 0

    let caretIndex = paragraphSource.distance(from: paragraphSource.startIndex, to: paragraphSource.range(of: "，弱一点")!.lowerBound) + 1
    let point = try page.json(
        """
        (function() {
          var block = window.__test.elementWithText('#content p', '很多人以为');
          var point = window.__test.pointForChar(block, \(caretIndex));
          if (!point) { return JSON.stringify({ ok: false }); }
          window.__test.clickAt(point.x, point.y);
          return JSON.stringify({ ok: true });
        })()
        """
    )
    checks.isTrue("scenario 1: the click point resolves inside the paragraph", (point["ok"] as? Bool) == true)

    let state = try page.json("window.__test.state()")
    checks.equal("scenario 1: exactly one block becomes editable", state["editableCount"] as? Int ?? -1, 1)
    checks.equal("scenario 1: the block keeps its rendered element", state["blockTag"] as? String ?? "", "P")
    checks.equal("scenario 1: no textarea appears", state["textareas"] as? Int ?? -1, 0)
    checks.equal("scenario 1: no overlay element is appended to the page", state["bodyChildren"] as? Int ?? -1, beforeBodyChildren)
    let bodyText = state["bodyText"] as? String ?? ""
    checks.isTrue("scenario 1: no save / cancel hint is shown", !bodyText.contains("保存") && !bodyText.contains("Esc"), "body text: \(bodyText.prefix(120))")
    checks.equal("scenario 1: the editable surface is a content block", state["blockIsDirectChild"] as? Bool ?? false, true)
    checks.equal("scenario 1: the editable surface stays in the document flow", state["blockPosition"] as? String ?? "", "static")
    checks.equal("scenario 1: the editable surface adds no floating descendants", state["floatingDescendants"] as? Int ?? -1, 0)
    checks.equal("scenario 1: the selection is collapsed", state["collapsed"] as? Bool ?? false, true)
    checks.equal("scenario 1: the caret sits inside the clicked block", state["anchorInsideEditable"] as? Bool ?? false, true)
    checks.equalText("scenario 1: the caret lands under the pointer", state["caretPrefix"] as? String ?? "", "很多人以为这得看模型强弱，")
    checks.approx("scenario 1: the block does not move vertically when editing starts", state["blockTop"] as? Double, beforeTop ?? 0)
    checks.approx("scenario 1: the block does not shift horizontally", state["blockLeft"] as? Double, beforeLeft ?? 0)

    // MARK: Scenario 2 — typing lands at the caret; committing rewrites only that block

    let typed = try page.eval("window.__test.type('非常')") as? Bool ?? false
    checks.isTrue("scenario 2: text insertion is accepted by the editable block", typed)

    let typingState = try page.json("window.__test.state()")
    let blockText = typingState["blockText"] as? String ?? ""
    checks.isTrue("scenario 2: typed text lands at the caret", blockText.contains("强弱，非常弱一点"), "block text: \(blockText)")
    checks.approx("scenario 2: typing does not shift the block", typingState["blockTop"] as? Double, beforeTop ?? 0)

    try page.eval("window.__test.clickOutsideContent(); true")
    let afterCommit = try page.json("window.__test.state()")
    checks.equal("scenario 2: clicking outside ends the edit", afterCommit["editableCount"] as? Int ?? -1, 0)

    let committed = try page.flush()
    checks.equalText(
        "scenario 2: only the edited block changes in the committed markdown",
        normalized(committed),
        normalized("# 标题\n\n\(paragraphEdited)\n\n下面四步把它证明出来。")
    )
    let posts = try page.eval("JSON.stringify(window.__testPosts || [])") as? String ?? "[]"
    checks.isTrue(
        "scenario 2: the commit is pushed to the host as a document change",
        posts.contains("\"change\"") && posts.contains(paragraphEdited),
        "posts: \(posts.prefix(200))"
    )

    // MARK: Scenario 3 — structure survives round-trips

    func editAndCommit(_ markdown: String, needle: String, insert: String) throws -> String {
        try page.render(markdown)
        try page.installEditor(locked: false)
        let needleLiteral = try jsStringLiteral(needle)
        let insertLiteral = try jsStringLiteral(insert)
        let clicked = try page.eval(
            """
            (function() {
              var el = window.__test.elementWithText('#content *', \(needleLiteral));
              if (!el) { return false; }
              var block = window.__test.blockFor(el);
              if (!block) { return false; }
              var index = (block.textContent || '').lastIndexOf(\(needleLiteral)) + \(needleLiteral).length;
              var point = window.__test.pointForChar(block, index);
              if (!point) { return false; }
              window.__test.clickAt(point.x, point.y);
              return window.__test.editableBlocks().length > 0;
            })()
            """
        ) as? Bool ?? false
        guard clicked else {
            checks.isTrue("scenario 3: the block containing \"\(needle)\" becomes editable", false)
            return ""
        }
        try page.eval("window.__test.type(\(insertLiteral)); true")
        try page.eval("window.__test.clickOutsideContent(); true")
        return try page.flush()
    }

    let headingResult = try editAndCommit("# 标题\n\n正文一。\n", needle: "标题", insert: "（改）")
    checks.equalText(
        "scenario 3: a heading keeps its marker and untouched blocks stay intact",
        normalized(headingResult),
        normalized("# 标题（改）\n\n正文一。")
    )

    let listResult = try editAndCommit("- 第一条\n- 第二条\n", needle: "第二条", insert: "改")
    checks.equalText(
        "scenario 3: a list keeps its marker and its sibling items",
        normalized(listResult),
        normalized("- 第一条\n- 第二条改")
    )

    let quoteResult = try editAndCommit("> 引用一行\n", needle: "引用一行", insert: "。")
    checks.equalText(
        "scenario 3: a blockquote keeps its marker",
        normalized(quoteResult),
        normalized("> 引用一行。")
    )

    let codeResult = try editAndCommit("```swift\nlet x = 1\n```\n", needle: "let x = 1", insert: " // 改")
    checks.equalText(
        "scenario 3: a fenced code block keeps its fence and language",
        normalized(codeResult),
        normalized("```swift\nlet x = 1 // 改\n```")
    )

    let inlineResult = try editAndCommit("这是**加粗**文字。\n", needle: "加粗", insert: "X")
    checks.isTrue(
        "scenario 3: inline emphasis markers survive",
        inlineResult.contains("这是**加粗") && inlineResult.contains("X") && inlineResult.contains("文字。"),
        "committed: \(inlineResult)"
    )
    checks.isTrue(
        "scenario 3: inline emphasis is not flattened into plain text",
        !inlineResult.contains("这是加粗X文字") && !inlineResult.contains("这是加粗文字"),
        "committed: \(inlineResult)"
    )

    // MARK: Scenario 4 — rich blocks are never corrupted

    let complexDocument = """
    # 富块

    ```mermaid
    graph TD; A-->B;
    ```

    $$
    x = 1
    $$

    ![测试图](pixel.png)

    | 甲 | 乙 |
    | --- | --- |
    | 1 | 2 |
    """
    try page.render(complexDocument)
    try page.installEditor(locked: false)
    checks.isTrue(
        "scenario 4: the mermaid diagram renders",
        try page.waitFor("document.querySelectorAll('#content .cmux-mermaid svg').length > 0")
    )
    checks.isTrue(
        "scenario 4: the display math renders",
        try page.waitFor("document.querySelectorAll('#content .cmux-math-display .katex').length > 0")
    )

    let richCases: [(label: String, selector: String, markers: [String])] = [
        ("mermaid", "#content .cmux-mermaid", ["```mermaid", "graph TD; A-->B;"]),
        ("math", "#content .cmux-math-display", ["$$", "x = 1"]),
        ("image", "#content img", ["![测试图](pixel.png)"]),
        ("table", "#content table", ["| 甲 | 乙 |", "| --- | --- |", "| 1 | 2 |"]),
    ]
    for testCase in richCases {
        try page.render(complexDocument)
        try page.installEditor(locked: false)
        if testCase.selector.contains("cmux") {
            _ = try page.waitFor("document.querySelectorAll('\(testCase.selector)').length > 0")
        }
        let clicked = try page.eval(
            """
            (function() {
              var el = document.querySelector('\(testCase.selector)');
              if (!el) { return false; }
              var block = window.__test.blockFor(el) || el;
              var rect = block.getBoundingClientRect();
              window.__test.clickAt(rect.left + 2, rect.top + Math.max(2, rect.height / 2));
              return window.__test.editableBlocks().length > 0;
            })()
            """
        ) as? Bool ?? false
        if clicked {
            try page.eval("window.__test.type('X'); true")
            try page.eval("window.__test.clickOutsideContent(); true")
            let output = try page.flush()
            for marker in testCase.markers {
                checks.isTrue("scenario 4: \(testCase.label) keeps \(marker)", output.contains(marker), "output:\n\(output)")
            }
        } else {
            let output = try page.flush()
            checks.equalText(
                "scenario 4: \(testCase.label) stays byte-identical when it is not editable",
                normalized(output),
                normalized(complexDocument)
            )
        }
    }

    // MARK: Scenario 5 — the editing surface scrolls with the page

    let longDocument = (1...60).map { index in "第 \(index) 段：这一段的正文足够长，方便滚动验证。" }.joined(separator: "\n\n")
    try page.render(longDocument)
    try page.installEditor(locked: false)
    let scrollSetup = try page.json(
        """
        (function() {
          var el = window.__test.elementWithText('#content p', '第 40 段');
          if (!el) { return JSON.stringify({ ok: false }); }
          el.scrollIntoView({ block: 'center', behavior: 'instant' });
          var block = window.__test.blockFor(el);
          var index = (block.textContent || '').indexOf('方便');
          var point = window.__test.pointForChar(block, index < 0 ? 2 : index);
          if (!point) { return JSON.stringify({ ok: false }); }
          window.__test.clickAt(point.x, point.y);
          var before = block.getBoundingClientRect();
          var startScroll = window.scrollY;
          window.scrollTo({ top: startScroll + 120, behavior: 'instant' });
          var after = block.getBoundingClientRect();
          return JSON.stringify({
            ok: true,
            beforeTop: before.top,
            afterTop: after.top,
            scrolled: window.scrollY,
            editableCount: window.__test.editableBlocks().length,
            position: getComputedStyle(block).position
          });
        })()
        """
    )
    checks.isTrue("scenario 5: the scrolled paragraph resolves", (scrollSetup["ok"] as? Bool) == true)
    let scrollDelta = (scrollSetup["beforeTop"] as? Double ?? 0) - (scrollSetup["afterTop"] as? Double ?? 0)
    checks.isTrue("scenario 5: the page actually scrolled", (number(scrollSetup["scrolled"]) ?? 0) > 0, "scrollY \(scrollSetup["scrolled"] ?? "nil")")
    checks.approx("scenario 5: the editing surface scrolls with the text", scrollDelta, 120, tolerance: 3)
    checks.equal("scenario 5: the edited block survives scrolling", scrollSetup["editableCount"] as? Int ?? -1, 1)
    try page.eval("window.scrollTo({ top: 0, behavior: 'instant' }); true")

    // MARK: Scenario 6 — locked documents refuse edits without chrome

    try page.render(baseDocument)
    try page.installEditor(locked: true)
    let lockedState = try page.json(
        """
        (function() {
          var block = window.__test.elementWithText('#content p', '很多人以为');
          var point = window.__test.pointForChar(block, 4);
          if (point) { window.__test.clickAt(point.x, point.y); }
          return window.__test.state();
        })()
        """
    )
    checks.equal("scenario 6: locked documents stay read-only", lockedState["editableCount"] as? Int ?? -1, 0)
    checks.equal("scenario 6: locked documents show no textarea", lockedState["textareas"] as? Int ?? -1, 0)
    checks.equalText("scenario 6: locked documents keep their source", normalized(try page.flush()), normalized(baseDocument))

    // MARK: Scenario 7 — Escape ends the edit without losing the typed text

    try page.render(baseDocument)
    try page.installEditor(locked: false)
    _ = try page.eval(
        """
        (function() {
          var block = window.__test.elementWithText('#content p', '很多人以为');
          var point = window.__test.pointForChar(block, 2);
          if (point) { window.__test.clickAt(point.x, point.y); }
          return true;
        })()
        """
    )
    try page.eval("window.__test.type('插'); true")
    try page.eval(
        """
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true, cancelable: true }));
        true
        """
    )
    let afterEscape = try page.json("window.__test.state()")
    checks.equal("scenario 7: Escape leaves the edit", afterEscape["editableCount"] as? Int ?? -1, 0)
    let escapedText = try page.flush()
    checks.isTrue("scenario 7: Escape keeps what was typed", escapedText.contains("很多插人以为"), "flushed: \(escapedText.prefix(120))")

    // MARK: Scenario 8 — a re-render after committing stays editable

    try page.render(baseDocument)
    try page.installEditor(locked: false)
    _ = try page.eval(
        """
        (function() {
          var block = window.__test.elementWithText('#content p', '很多人以为');
          var point = window.__test.pointForChar(block, 3);
          if (point) { window.__test.clickAt(point.x, point.y); }
          return true;
        })()
        """
    )
    try page.eval("window.__test.type('甲'); true")
    try page.eval("window.__test.clickOutsideContent(); true")
    let rerendered = try page.flush()
    checks.isTrue("scenario 8: the commit contains the typed text", rerendered.contains("很多人甲以为"), "committed: \(rerendered.prefix(160))")

    try page.render(rerendered)
    let reedit = try page.json(
        """
        (function() {
          var el = window.__test.elementWithText('#content p', '很多人甲以为');
          if (!el) { return JSON.stringify({ ok: false }); }
          var block = window.__test.blockFor(el);
          var point = window.__test.pointForChar(block, 2);
          if (point) { window.__test.clickAt(point.x, point.y); }
          return JSON.stringify({ ok: true, state: JSON.parse(window.__test.state()) });
        })()
        """
    )
    let reeditState = reedit["state"] as? [String: Any] ?? [:]
    checks.equal("scenario 8: a re-rendered block becomes editable again", reeditState["editableCount"] as? Int ?? -1, 1)
    checks.isTrue(
        "scenario 8: the committed text survives the re-render",
        (reeditState["blockText"] as? String ?? "").contains("很多人甲以为"),
        "block text: \(reeditState["blockText"] ?? "nil")"
    )
    // MARK: Scenario 9 — clicking another block commits the open one

    // Scenario 8 leaves an edit open; close it before swapping documents.
    _ = try page.flush()
    try page.eval("window.__test.clickOutsideContent(); true")
    try page.render("# 甲\n\n乙段。\n")
    try page.installEditor(locked: false)
    _ = try page.eval(
        """
        (function() {
          var block = window.__test.elementWithText('#content p', '乙段');
          var point = window.__test.pointForChar(block, 1);
          if (point) { window.__test.clickAt(point.x, point.y); }
          return true;
        })()
        """
    )
    try page.eval("window.__test.type('一'); true")
    let switched = try page.json(
        """
        (function() {
          var heading = document.querySelector('#content h1');
          var point = window.__test.pointForChar(heading, 1);
          if (point) { window.__test.clickAt(point.x, point.y); }
          return window.__test.state();
        })()
        """
    )
    checks.equal("scenario 9: the previous edit is committed before the new block opens", switched["editableCount"] as? Int ?? -1, 1)
    let switchedText = switched["blockText"] as? String ?? ""
    checks.isTrue("scenario 9: the newly clicked block is the editable one", switchedText.contains("甲"), "block text: \(switchedText)")
    try page.eval("window.__test.type('二'); true")
    let bothEdits = try page.flush()
    checks.equalText("scenario 9: switching blocks keeps both edits", normalized(bothEdits), normalized("# 甲二\n\n乙一段。"))
} catch {
    print("❌ harness error: \(error)")
    exit(1)
}

exit(checks.report())
