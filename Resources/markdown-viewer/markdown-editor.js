// In-place editing for the cmux Markdown viewer.
//
// Design note: the rendered document stays the layout source of truth. When
// editing is unlocked, activating a block swaps *that block only* for its own
// Markdown source, and committing writes those bytes back into the document.
// Nothing is ever re-serialized from HTML, so a save cannot rewrite blocks the
// user did not touch — the failure mode of "contenteditable over rendered
// HTML" editors.
//
// The lock/pencil pill mirrors VS Code's Markdown Editor: a segmented control
// pinned to the top-right of the content, plus a shine sweep across the pill
// whenever someone tries to edit while it is locked.
(function(global) {
  'use strict';

  var BLOCK_ATTRIBUTE_START = 'data-cmux-block-start';
  var BLOCK_ATTRIBUTE_END = 'data-cmux-block-end';
  var ACTIVE_CLASS = 'cmux-block-editing';

  var contentEl = null;
  var sourceText = '';
  var locked = false;
  var installed = false;
  var activeBlock = null;
  var postToHost = null;
  var pointerStart = null;

  // MARK: - Source ranges

  /**
   * Walks `marked`'s top-level tokens and the rendered DOM children in
   * parallel, stamping each rendered element with the source range it came
   * from. Tokens that render nothing (blank-line trivia) advance the source
   * offset without consuming a node; tokens that render several nodes (raw
   * HTML blocks) stamp every one of them with the same range.
   */
  // The viewer wraps some rendered nodes (code blocks get a
  // `div.cmux-code-block` for the copy button), so a token can own a wrapper
  // plus its inner element. These are the elements a token type may render.
  function expectedTags(type) {
    switch (type) {
      case 'heading': return ['H1', 'H2', 'H3', 'H4', 'H5', 'H6'];
      case 'paragraph': return ['P', 'DIV', 'FIGURE'];
      case 'list': return ['UL', 'OL'];
      case 'blockquote': return ['BLOCKQUOTE'];
      case 'table': return ['TABLE'];
      case 'code': return ['PRE', 'DIV'];
      case 'hr': return ['HR'];
      default: return null;
    }
  }

  function stampBlockRanges(markdown) {
    var marked = global.marked;
    if (!marked || !contentEl) { return; }
    var tokens;
    try {
      tokens = marked.lexer(markdown);
    } catch (error) {
      return;
    }
    var offset = 0;
    var children = Array.prototype.slice.call(contentEl.children);
    var index = 0;
    var stamped = [];
    for (var i = 0; i < tokens.length && index < children.length; i++) {
      var token = tokens[i];
      var raw = typeof token.raw === 'string' ? token.raw : '';
      var start = offset;
      offset += raw.length;
      if (!raw) { continue; }
      if (token.type === 'space') { continue; }

      var wanted = expectedTags(token.type);
      // Raw HTML and plain-text tokens are the only ones that can render more
      // than one top-level node; everything else is one element (plus, for
      // code blocks, the viewer's wrapper). Probing them keeps stamping linear
      // even on very large documents.
      var budget = (token.type === 'html' || token.type === 'text') ? 8 : 2;
      var consumed = [];
      for (var guard = 0; guard < budget && index < children.length; guard++) {
        var candidate = children[index];
        consumed.push(candidate);
        index++;
        if (!wanted || wanted.indexOf(candidate.tagName) >= 0) { break; }
        if (candidate.tagName !== 'DIV') { break; }
      }
      for (var c = 0; c < consumed.length; c++) {
        var element = consumed[c];
        element.setAttribute(BLOCK_ATTRIBUTE_START, String(start));
        element.setAttribute(BLOCK_ATTRIBUTE_END, String(offset));
        element.classList.add('cmux-block');
        stamped.push(element);
      }
    }

    // Guarantee that the ranges tile the whole document: a rendering wrapper,
    // a sanitizer drop or an unhandled token may shift the token/element
    // pairing by a node. Absorbing the leftover bytes into the neighbouring block is
    // always safe — the textarea then simply shows a few marker characters
    // more, and committing it unchanged writes them back verbatim.
    var cursor = 0;
    for (var s = 0; s < stamped.length; s++) {
      var node = stamped[s];
      var nodeStart = Number(node.getAttribute(BLOCK_ATTRIBUTE_START));
      var nodeEnd = Number(node.getAttribute(BLOCK_ATTRIBUTE_END));
      if (!Number.isFinite(nodeStart)) { nodeStart = cursor; }
      if (!Number.isFinite(nodeEnd) || nodeEnd < nodeStart) { nodeEnd = nodeStart; }
      if (nodeStart > cursor) { nodeStart = cursor; }
      // `marked` can report a token `raw` that runs one newline past the
      // document; clamp so a range never points outside the source.
      nodeStart = Math.min(nodeStart, markdown.length);
      nodeEnd = Math.min(nodeEnd, markdown.length);
      node.setAttribute(BLOCK_ATTRIBUTE_START, String(nodeStart));
      node.setAttribute(BLOCK_ATTRIBUTE_END, String(nodeEnd));
      cursor = Math.max(cursor, nodeEnd);
    }
    if (stamped.length > 0 && cursor < markdown.length) {
      stamped[stamped.length - 1].setAttribute(BLOCK_ATTRIBUTE_END, String(markdown.length));
    }
  }

  function blockElementAt(target) {
    var element = target && target.closest ? target.closest('[' + BLOCK_ATTRIBUTE_START + ']') : null;
    if (!element || !contentEl.contains(element)) { return null; }
    return element;
  }

  function blockRange(element) {
    var start = Number(element.getAttribute(BLOCK_ATTRIBUTE_START));
    var end = Number(element.getAttribute(BLOCK_ATTRIBUTE_END));
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) { return null; }
    return { start: start, end: end };
  }

  // MARK: - Lock state

  function syncLockUI() {
    var pill = document.getElementById('cmux-markdown-lock');
    if (!pill) { return; }
    pill.classList.toggle('is-locked', locked);
    // Same state wording as VS Code's toggle (it uses the label instead of
    // aria-pressed, so assistive tech hears the action, not a toggle state).
    pill.setAttribute('aria-label', locked ? 'Locked; switch to editing' : 'Editing; switch to locked mode');
    pill.setAttribute('title', locked ? 'Read-only: editing disabled. Click to edit.' : 'Editing enabled. Click to lock.');
    if (!locked) { pill.classList.remove('cmux-shine'); }
    if (contentEl) { contentEl.classList.toggle('cmux-locked', locked); }
  }

  function shineLockPill() {
    var pill = document.getElementById('cmux-markdown-lock');
    if (!pill || pill.classList.contains('cmux-shine')) { return; }
    pill.classList.add('cmux-shine');
  }

  function setLocked(next) {
    locked = !!next;
    // Locking must not throw away the block the user is in the middle of
    // editing; commit it first, then switch to read-only.
    if (locked) { closeActiveBlock(true, true); }
    syncLockUI();
  }

  // MARK: - Block editing

  // Rendered nodes that cannot be turned back into their own source by
  // serializing the HTML: diagrams, math, images, tables, embedded controls.
  // A block holding any of them stays read-only — refusing to open it is
  // always better than rewriting hand-written markup into something else.
  var UNEDITABLE_SELECTOR = [
    'img', 'svg', 'canvas', 'iframe', 'video', 'audio',
    'table', 'input', 'textarea', 'select',
    '.cmux-mermaid', '.cmux-vega', '.cmux-math', '.cmux-frontmatter',
    'mjx-container', '.katex'
  ].join(', ');

  // Elements whose children are blocks rather than one inline run.
  var BLOCK_TAGS = {
    P: true, DIV: true, H1: true, H2: true, H3: true, H4: true, H5: true,
    H6: true, UL: true, OL: true, LI: true, BLOCKQUOTE: true, PRE: true,
    DL: true, DT: true, DD: true, FIGURE: true, FIGCAPTION: true,
    DETAILS: true, SUMMARY: true, SECTION: true, ARTICLE: true
  };

  function isBlockTag(node) {
    return Boolean(node && node.nodeType === 1 && BLOCK_TAGS[node.tagName]);
  }

  // `matches` is checked as well as `querySelector`: when the clicked block
  // *is* the forbidden element (a `<table>`, a math block), querySelector only
  // looks at descendants and would let it open.
  function canEditBlock(block) {
    if (!block || block.nodeType !== 1) { return false; }
    if (block.matches(UNEDITABLE_SELECTOR)) { return false; }
    if (block.querySelector(UNEDITABLE_SELECTOR)) { return false; }
    // A void block (an `<hr>`, an empty rule) has nothing to put a caret in.
    if (!block.textContent && !block.querySelector('*')) { return false; }
    return true;
  }

  // Code blocks are wrapped in `div.cmux-code-block` for the copy button, so
  // the caret has to live inside the `<code>` element: making the wrapper
  // editable would put the button itself into the editable run.
  function editingHost(block) {
    if (block.tagName === 'PRE') { return block.querySelector('code') || block; }
    if (block.classList && block.classList.contains('cmux-code-block')) {
      return block.querySelector('pre > code') || block.querySelector('pre') || block;
    }
    return block;
  }

  // The caret has to be placed explicitly: a synthetic mousedown/mouseup pair
  // never moves WebKit's selection, and even for a real click the block only
  // became editable a moment ago. `caretRangeFromPoint` resolves the same
  // offset the browser would have used for a native click at that point.
  function placeCaret(host, point) {
    var selection = global.getSelection && global.getSelection();
    if (!selection) { return; }
    var range = null;
    if (point && global.document.caretRangeFromPoint) {
      try {
        range = global.document.caretRangeFromPoint(point.x, point.y);
      } catch (error) {
        range = null;
      }
    }
    if (!range || !host.contains(range.startContainer)) {
      // A point outside the run (the block's padding, a click past the last
      // line) opens the block with the caret where typing naturally continues.
      range = global.document.createRange();
      range.selectNodeContents(host);
      range.collapse(false);
    }
    selection.removeAllRanges();
    selection.addRange(range);
  }

  // MARK: - Single-block markdown serialization

  // Only the block the user edited is ever re-serialized; every other block is
  // copied byte for byte. These helpers therefore cover exactly what the
  // renderer can put inside one block, and `canEditBlock` refuses the blocks
  // they cannot express.
  function escapeText(text) {
    // Escaping keeps a typed "*" or "_" visible instead of turning it into
    // emphasis on the next render.
    return String(text == null ? '' : text).replace(/([\\`*_\[\]<])/g, '\\$1');
  }

  function inlineCodeSpan(text) {
    var value = String(text == null ? '' : text);
    var fence = '`';
    while (value.indexOf(fence) >= 0) { fence += '`'; }
    var pad = value.charAt(0) === '`' || value.charAt(value.length - 1) === '`' ? ' ' : '';
    return fence + pad + value + pad + fence;
  }

  function inlineLink(node, inner) {
    var href = node.getAttribute('href') || '';
    var label = inner || escapeText(node.textContent || '');
    return href ? '[' + label + '](' + href + ')' : label;
  }

  function inlineNode(node) {
    if (!node) { return ''; }
    if (node.nodeType === 3) { return escapeText(node.nodeValue); }
    if (node.nodeType !== 1) { return ''; }
    var tag = node.tagName;
    if (tag === 'BR') { return '  \n'; }
    if (tag === 'WBR' || tag === 'IMG') { return ''; }
    if (tag === 'CODE') { return inlineCodeSpan(node.textContent || ''); }
    var inner = inlineChildren(node);
    switch (tag) {
      case 'STRONG': case 'B': return inner.trim() ? '**' + inner + '**' : inner;
      case 'EM': case 'I': return inner.trim() ? '*' + inner + '*' : inner;
      case 'DEL': case 'S': case 'STRIKE': return inner.trim() ? '~~' + inner + '~~' : inner;
      case 'A': return inlineLink(node, inner);
      default:
        if (isBlockTag(node)) { return inner; }
        // Everything else the renderer can emit inline (mark, kbd, sup, sub,
        // ins, small, abbr, …) is kept as inline HTML so its formatting
        // survives the round-trip instead of being flattened into plain text.
        return '<' + tag.toLowerCase() + '>' + inner + '</' + tag.toLowerCase() + '>';
    }
  }

  function inlineChildren(node) {
    var out = '';
    var children = node ? node.childNodes : [];
    for (var i = 0; i < children.length; i++) { out += inlineNode(children[i]); }
    return out;
  }

  function languageFromClass(value) {
    var match = /(?:^|\s)language-([\w+#.-]+)/.exec(value || '');
    return match ? match[1] : '';
  }

  function serializeCodeBlock(block) {
    var code = block.tagName === 'CODE' ? block : block.querySelector('code');
    var element = code || block;
    var raw = element.textContent || '';
    var language = languageFromClass(element.className) || languageFromClass(block.className);
    // The `<pre>` text owns the trailing newline the fence needs.
    raw = raw.replace(/\n$/, '');
    var fence = '```';
    while (raw.indexOf(fence) >= 0) { fence += '`'; }
    return fence + language + '\n' + raw + '\n' + fence;
  }

  function serializeListItem(item, marker, indent) {
    var nodes = Array.prototype.slice.call(item.childNodes);
    var inlineRun = '';
    var nested = [];
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (node.nodeType === 1 && (node.tagName === 'UL' || node.tagName === 'OL')) {
        nested.push(node);
        continue;
      }
      if (isBlockTag(node)) {
        // A loose item (`<li><p>text</p>`) keeps its text on the marker line.
        inlineRun += inlineChildren(node);
        var innerLists = Array.prototype.slice.call(node.children).filter(function(child) {
          return child.tagName === 'UL' || child.tagName === 'OL';
        });
        nested = nested.concat(innerLists);
        continue;
      }
      inlineRun += inlineNode(node);
    }
    var text = inlineRun.replace(/\s+$/, '');
    var lines = [text ? indent + marker + text : indent + marker.replace(/\s+$/, '')];
    for (var n = 0; n < nested.length; n++) { lines.push(serializeList(nested[n], indent + '  ')); }
    return lines.join('\n');
  }

  function serializeList(list, indent) {
    var prefix = indent || '';
    var ordered = list.tagName === 'OL';
    var start = Number(list.getAttribute('start') || '1');
    if (!Number.isFinite(start)) { start = 1; }
    var items = Array.prototype.slice.call(list.children).filter(function(child) {
      return child.tagName === 'LI';
    });
    var parts = [];
    for (var i = 0; i < items.length; i++) {
      var marker = ordered ? (start + i) + '. ' : '- ';
      parts.push(serializeListItem(items[i], marker, prefix));
    }
    return parts.join('\n');
  }

  function serializeBlockquote(element) {
    var inner = serializeChildren(element);
    if (!inner) { return '>'; }
    return inner.split('\n').map(function(line) {
      return line ? '> ' + line : '>';
    }).join('\n');
  }

  function serializeHeading(element) {
    var level = Number(element.tagName.charAt(1)) || 1;
    var text = inlineChildren(element).replace(/\s+$/, '');
    return new Array(level + 1).join('#') + (text ? ' ' + text : '');
  }

  function serializeChildren(element) {
    var parts = [];
    var children = element ? element.children : [];
    for (var i = 0; i < children.length; i++) {
      var part = serializeElement(children[i]);
      if (typeof part === 'string' && part) { parts.push(part); }
    }
    return parts.join('\n\n');
  }

  /// Returns the markdown for one rendered block, or `null` when this block is
  /// not one of the shapes the serializer can reproduce faithfully.
  function serializeElement(element) {
    if (!element || element.nodeType !== 1) { return null; }
    var tag = element.tagName;
    if (/^H[1-6]$/.test(tag)) { return serializeHeading(element); }
    if (tag === 'UL' || tag === 'OL') { return serializeList(element); }
    if (tag === 'BLOCKQUOTE') { return serializeBlockquote(element); }
    if (tag === 'PRE') { return serializeCodeBlock(element); }
    if (tag === 'HR') { return '---'; }
    if (element.classList && element.classList.contains('cmux-code-block')) {
      return serializeCodeBlock(element);
    }
    if (tag === 'TABLE' || tag === 'IMG' || tag === 'DL' || tag === 'DETAILS' || tag === 'FIGURE') {
      // Not expressible as regenerated markdown; `canEditBlock` refuses them
      // anyway, this keeps a stray path from blanking them out.
      return null;
    }
    // Paragraph-ish: one inline run.
    return inlineChildren(element).replace(/^\s+/, '').replace(/\s+$/, '');
  }

  // MARK: - Committing one block

  // After a commit the following blocks' byte ranges are stale until the host
  // re-renders. Shifting them here keeps a second edit inside the same render
  // writing to the right offsets.
  function rebaseBlockRanges(element, delta) {
    if (!delta || !contentEl) { return; }
    var children = Array.prototype.slice.call(contentEl.children);
    var index = children.indexOf(element);
    if (index < 0) { return; }
    for (var i = index; i < children.length; i++) {
      var node = children[i];
      var start = Number(node.getAttribute(BLOCK_ATTRIBUTE_START));
      var end = Number(node.getAttribute(BLOCK_ATTRIBUTE_END));
      if (!Number.isFinite(start) || !Number.isFinite(end)) { continue; }
      if (i === index) {
        node.setAttribute(BLOCK_ATTRIBUTE_END, String(end + delta));
      } else {
        node.setAttribute(BLOCK_ATTRIBUTE_START, String(start + delta));
        node.setAttribute(BLOCK_ATTRIBUTE_END, String(end + delta));
      }
    }
  }

  function commitBlock(state, notify) {
    var range = blockRange(state.element);
    if (!range) { return; }
    var raw = sourceText.slice(range.start, range.end);
    var core = serializeElement(state.element);
    if (typeof core !== 'string') { return; }
    // Never blank out a block whose text the serializer could not read.
    if (!core && String(state.element.textContent || '').trim()) { return; }
    // The block's range also owns the blank lines around it (`marked` reports
    // them as trivia of a neighbouring token); they are carried over verbatim
    // so the surrounding document keeps its exact byte layout.
    var lead = (/^[\r\n]*/.exec(raw) || [''])[0];
    var trail = (/[\r\n]*$/.exec(raw) || [''])[0];
    if (lead.length + trail.length > raw.length) { lead = raw; trail = ''; }
    var next = lead + core + trail;
    if (next === raw) { return; }
    var delta = next.length - raw.length;
    sourceText = sourceText.slice(0, range.start) + next + sourceText.slice(range.end);
    rebaseBlockRanges(state.element, delta);
    if (postToHost && notify !== false) { postToHost({ type: 'change', text: sourceText }); }
  }

  function detachBlockEditing(state) {
    global.document.removeEventListener('mousedown', state.onOutsidePointer, true);
    global.document.removeEventListener('keydown', state.onKeyDown, true);
    try {
      var selection = global.getSelection && global.getSelection();
      if (selection && selection.rangeCount > 0 && state.host.contains(selection.anchorNode)) {
        selection.removeAllRanges();
      }
    } catch (error) { /* the selection can be owned by another document */ }
    state.element.classList.remove(ACTIVE_CLASS);
    state.host.removeAttribute('contenteditable');
    state.host.removeAttribute('spellcheck');
  }

  function closeActiveBlock(commit, notify) {
    var state = activeBlock;
    if (!state) { return; }
    activeBlock = null;
    detachBlockEditing(state);
    if (commit === false) { return; }
    // A detached block means the document was re-rendered under the edit: the
    // recorded offsets no longer describe anything, so the edit is dropped
    // instead of being written into the wrong place.
    if (!state.element.isConnected || !contentEl || !contentEl.contains(state.element)) { return; }
    commitBlock(state, notify);
  }

  /// Drops the open edit without writing anything (used when a re-render
  /// replaced the element the caret was living in).
  function discardActiveBlock() {
    var state = activeBlock;
    if (!state) { return; }
    activeBlock = null;
    detachBlockEditing(state);
  }

  function openBlock(element, point) {
    if (locked) {
      shineLockPill();
      return;
    }
    if (activeBlock) {
      if (activeBlock.element === element) { return; }
      closeActiveBlock(true, true);
    }
    var range = blockRange(element);
    if (!range) { return; }
    if (!canEditBlock(element)) { return; }
    var host = editingHost(element);
    if (!host || !canEditBlock(host)) { return; }

    var state = { element: element, host: host, onOutsidePointer: null, onKeyDown: null };
    state.onOutsidePointer = function(event) {
      if (activeBlock !== state) { return; }
      if (state.element.contains(event.target) || state.host.contains(event.target)) { return; }
      closeActiveBlock(true, true);
    };
    state.onKeyDown = function(event) {
      if (activeBlock !== state) { return; }
      if (event.key === 'Escape') {
        // VS Code's editor has no "rollback on Escape": the typed text stays.
        event.preventDefault();
        closeActiveBlock(true, true);
        return;
      }
      if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        closeActiveBlock(true, true);
        return;
      }
      if (event.key === 'Enter' && !event.shiftKey) {
        // Splitting one rendered block into two would leave the second half
        // without a source range; a hard break keeps the block a single unit.
        event.preventDefault();
        if (global.document.execCommand) { global.document.execCommand('insertLineBreak'); }
      }
    };
    activeBlock = state;
    element.classList.add(ACTIVE_CLASS);
    host.setAttribute('contenteditable', 'true');
    host.setAttribute('spellcheck', 'false');
    try {
      host.focus({ preventScroll: true });
    } catch (error) {
      try { host.focus(); } catch (ignored) { /* older WebKit: focus is best effort */ }
    }
    placeCaret(host, point);
    global.document.addEventListener('mousedown', state.onOutsidePointer, true);
    global.document.addEventListener('keydown', state.onKeyDown, true);
  }

  // MARK: - Wiring

  function installLockPill() {
    if (document.getElementById('cmux-markdown-lock')) { return; }
    var pill = document.createElement('button');
    pill.id = 'cmux-markdown-lock';
    pill.type = 'button';
    pill.className = 'cmux-markdown-lock';
    pill.innerHTML =
      '<span class="cmux-lock-indicator" aria-hidden="true"></span>' +
      '<svg class="cmux-lock-icon cmux-lock-icon-locked" viewBox="0 0 16 16" width="16" height="16" fill="currentColor" aria-hidden="true">' +
      '<path d="M8 9C8.55228 9 9 9.44771 9 10C9 10.5523 8.55228 11 8 11C7.44772 11 7 10.5523 7 10C7 9.44771 7.44772 9 8 9Z"/>' +
      '<path fill-rule="evenodd" clip-rule="evenodd" d="M8 1C9.654 1 11 2.346 11 4V6H12C13.103 6 14 6.897 14 8V13C14 14.103 13.103 15 12 15H4C2.897 15 2 14.103 2 13V8C2 6.897 2.897 6 4 6H5V4C5 2.346 6.346 1 8 1ZM4 7C3.449 7 3 7.449 3 8V13C3 13.551 3.449 14 4 14H12C12.551 14 13 13.551 13 13V8C13 7.449 12.551 7 12 7H4ZM8 2C6.897 2 6 2.897 6 4V6H10V4C10 2.897 9.103 2 8 2Z"/>' +
      '</svg>' +
      '<svg class="cmux-lock-icon cmux-lock-icon-editing" viewBox="0 0 16 16" width="16" height="16" fill="currentColor" aria-hidden="true">' +
      '<path d="M14.236 1.76386C13.2123 0.740172 11.5525 0.740171 10.5289 1.76386L2.65722 9.63549C2.28304 10.0097 2.01623 10.4775 1.88467 10.99L1.01571 14.3755C0.971767 14.5467 1.02148 14.7284 1.14646 14.8534C1.27144 14.9783 1.45312 15.028 1.62432 14.9841L5.00978 14.1151C5.52234 13.9836 5.99015 13.7168 6.36433 13.3426L14.236 5.47097C15.2596 4.44728 15.2596 2.78755 14.236 1.76386ZM11.236 2.47097C11.8691 1.8378 12.8957 1.8378 13.5288 2.47097C14.162 3.10413 14.162 4.1307 13.5288 4.76386L12.75 5.54269L10.4571 3.24979L11.236 2.47097ZM9.75002 3.9569L12.0429 6.24979L5.65722 12.6355C5.40969 12.883 5.10023 13.0595 4.76117 13.1465L2.19447 13.8053L2.85327 11.2386C2.9403 10.8996 3.1168 10.5901 3.36433 10.3426L9.75002 3.9569Z"/>' +
      '</svg>';

    pill.addEventListener('animationend', function(event) {
      if (event.animationName === 'cmux-lock-shine') { pill.classList.remove('cmux-shine'); }
    });

    pill.addEventListener('click', function() {
      locked = !locked;
      if (locked) { closeActiveBlock(true, true); }
      syncLockUI();
      if (postToHost) { postToHost({ type: 'readonly', value: locked }); }
    });

    var host = document.getElementById('cmux-markdown-lock-host');
    if (!host) {
      host = document.createElement('div');
      host.id = 'cmux-markdown-lock-host';
      host.className = 'cmux-markdown-lock-host';
      document.body.appendChild(host);
    }
    host.appendChild(pill);
    syncLockUI();
  }

  function installClickHandling() {
    if (contentEl.__cmuxEditorClickInstalled) { return; }
    contentEl.__cmuxEditorClickInstalled = true;

    contentEl.addEventListener('mousedown', function(event) {
      if (event.button !== 0) { return; }
      pointerStart = { x: event.clientX, y: event.clientY, target: event.target };
    }, true);

    contentEl.addEventListener('mouseup', function(event) {
      var start = pointerStart;
      pointerStart = null;
      if (!installed || !start || event.button !== 0) { return; }
      // A drag is a text selection, not a block activation.
      if (Math.abs(event.clientX - start.x) > 4 || Math.abs(event.clientY - start.y) > 4) { return; }
      var selection = global.getSelection && global.getSelection();
      if (selection && !selection.isCollapsed) { return; }
      if (isEmbeddedControl(event.target)) { return; }
      var element = blockElementAt(event.target);
      if (!element) { return; }
      if (locked) {
        shineLockPill();
        return;
      }
      if (activeBlock && activeBlock.element === element) { return; }
      // The caret has to be resolved from the click itself: a synthetic
      // mousedown/mouseup pair never moves WebKit's selection, so the block
      // would open with the caret at its first character.
      openBlock(element, { x: event.clientX, y: event.clientY });
    }, true);
  }

  function isEmbeddedControl(target) {
    // Links, task checkboxes and other embedded controls keep their own
    // behaviour: activating a block must not swallow them.
    return Boolean(target && target.closest && target.closest('a[href], input, button, summary'));
  }

  var CmuxMarkdownEditor = {
    install: function(options) {
      options = options || {};
      contentEl = options.contentElement || document.getElementById('content');
      postToHost = options.postToHost || postToHost;
      locked = options.locked === true;
      installed = true;
      installLockPill();
      installClickHandling();
      syncLockUI();
      return CmuxMarkdownEditor;
    },
    /// Removes the editing affordances when the panel goes back to plain
    /// reading, without touching the rendered document.
    uninstall: function() {
      installed = false;
      closeActiveBlock(true, true);
      var host = document.getElementById('cmux-markdown-lock-host');
      if (host && host.parentNode) { host.parentNode.removeChild(host); }
      if (contentEl) { contentEl.classList.remove('cmux-locked'); }
    },
    markRendered: function(markdown) {
      if (typeof markdown === 'string') { sourceText = markdown; }
      if (!contentEl) { contentEl = document.getElementById('content'); }
      if (!contentEl) { return; }
      stampBlockRanges(sourceText);
      if (installed) {
        installLockPill();
        syncLockUI();
      }
    },
    setLocked: setLocked,
    isLocked: function() { return locked; },
    closeActiveBlock: function(commit) { closeActiveBlock(commit !== false, true); },
    /// Commits any open block and hands the canonical document back, so the
    /// host can save without waiting for a follow-up message.
    flush: function() {
      closeActiveBlock(true, false);
      return sourceText;
    }
  };

  global.CmuxMarkdownEditor = CmuxMarkdownEditor;
})(window);
