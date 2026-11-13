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
  var EDITOR_CLASS = 'cmux-block-editor';

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
    pill.setAttribute('aria-pressed', locked ? 'false' : 'true');
    pill.setAttribute('aria-label', locked ? 'Read only' : 'Editing');
    pill.setAttribute('title', locked ? 'Read only — click to edit' : 'Editing — click to lock');
    // Both icons stay visible (VS Code shows lock on the left, pen on the
    // right, always); the active one is picked out by the .is-locked class.
    if (contentEl) { contentEl.classList.toggle('cmux-locked', locked); }
  }

  function shineLockPill() {
    var pill = document.getElementById('cmux-markdown-lock');
    if (!pill) { return; }
    pill.classList.remove('cmux-shine');
    // Force a style flush so the animation restarts on rapid repeats.
    void pill.offsetWidth;
    pill.classList.add('cmux-shine');
    global.setTimeout(function() { pill.classList.remove('cmux-shine'); }, 900);
  }

  function setLocked(next) {
    locked = !!next;
    // Locking must not throw away the block the user is in the middle of
    // editing; commit it first, then switch to read-only.
    if (locked) { closeActiveBlock(true, true); }
    syncLockUI();
  }

  // MARK: - Block editing

  function closeActiveBlock(commit, notify) {
    if (!activeBlock) { return; }
    var state = activeBlock;
    activeBlock = null;
    var editor = state.editor;

    state.element.classList.remove(ACTIVE_CLASS);
    state.element.hidden = false;
    if (editor && editor.parentNode) { editor.parentNode.removeChild(editor); }
    global.document.removeEventListener('mousedown', state.onOutsidePointer, true);
    global.document.removeEventListener('keydown', state.onKeyDown, true);

    if (!commit) { return; }
    var range = blockRange(state.element);
    if (!range) { return; }
    var next = state.text;
    if (next === state.original) { return; }
    // The block's raw source owns its trailing blank lines, so they must
    // survive the replacement: dropping them would glue the edited block to
    // the next one on the re-render.
    var trailing = /[\r\n]+$/.exec(state.original);
    next = next.replace(/[ \t\r\n]+$/, '') + (trailing ? trailing[0] : '');
    var updated = sourceText.slice(0, range.start) + next + sourceText.slice(range.end);
    sourceText = updated;
    if (postToHost && notify !== false) { postToHost({ type: 'change', text: updated }); }
  }

  // The block editor floats on document.body, so it inherits nothing from the
  // palette MarkdownWebRenderer.applyTheme injects on #content. Copy the text
  // colours over from the rendered document, so the editor's text is literally
  // the same colour as the body text it is replacing — instead of falling back
  // to the light-theme defaults on a dark surface.
  function inheritContentPalette(el) {
    var content = document.getElementById('content');
    if (!content || !el) { return; }
    var cs = getComputedStyle(content);
    ['--fgColor-default', '--fgColor-muted'].forEach(function(name) {
      var value = cs.getPropertyValue(name).trim();
      if (value) { el.style.setProperty(name, value); }
    });
  }

  function openBlock(element) {
    if (locked) {
      shineLockPill();
      return;
    }
    if (activeBlock) {
      if (activeBlock.element === element) { return; }
      closeActiveBlock(true, true);
    }
    var range = blockRange(element);
    if (!range) {
      shineLockPill();
      return;
    }

    var rect = element.getBoundingClientRect();
    var editor = document.createElement('div');
    editor.className = EDITOR_CLASS;
    inheritContentPalette(editor);
    editor.style.left = Math.max(0, rect.left - 12) + 'px';
    editor.style.top = Math.max(0, rect.top - 8) + 'px';
    editor.style.width = Math.max(320, rect.width + 24) + 'px';

    var textarea = document.createElement('textarea');
    textarea.className = EDITOR_CLASS + '-input';
    textarea.spellcheck = false;
    textarea.value = sourceText.slice(range.start, range.end);
    editor.appendChild(textarea);

    var hint = document.createElement('div');
    hint.className = EDITOR_CLASS + '-hint';
    hint.textContent = '⌘↩ 保存 · Esc 取消';
    editor.appendChild(hint);

    document.body.appendChild(editor);
    autoSize(textarea);

    var state = {
      element: element,
      editor: editor,
      text: textarea.value,
      original: textarea.value,
      onOutsidePointer: function(event) {
        if (editor.contains(event.target)) { return; }
        closeActiveBlock(true, true);
      },
      onKeyDown: function(event) {
        if (event.key === 'Escape') {
          event.preventDefault();
          closeActiveBlock(false, false);
          return;
        }
        if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
          event.preventDefault();
          closeActiveBlock(true, true);
          return;
        }
      }
    };
    activeBlock = state;
    element.hidden = true;
    element.classList.add(ACTIVE_CLASS);

    textarea.addEventListener('input', function() {
      state.text = textarea.value;
      autoSize(textarea);
    });
    textarea.addEventListener('keydown', function(event) {
      event.stopPropagation();
    });

    global.document.addEventListener('mousedown', state.onOutsidePointer, true);
    global.document.addEventListener('keydown', state.onKeyDown, true);
    textarea.focus();
    textarea.setSelectionRange(textarea.value.length, textarea.value.length);
  }

  function autoSize(textarea) {
    textarea.style.height = 'auto';
    textarea.style.height = Math.max(48, textarea.scrollHeight + 8) + 'px';
  }

  // MARK: - Wiring

  function installLockPill() {
    if (document.getElementById('cmux-markdown-lock')) { return; }
    var pill = document.createElement('button');
    pill.id = 'cmux-markdown-lock';
    pill.type = 'button';
    pill.className = 'cmux-markdown-lock';
    pill.innerHTML =
      '<span class="cmux-lock-icon" aria-hidden="true">' +
      '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor">' +
      '<path d="M4 6.5V5a4 4 0 1 1 8 0v1.5h.5A1.5 1.5 0 0 1 14 8v5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 13V8a1.5 1.5 0 0 1 1.5-1.5H4Zm1.5 0h5V5a2.5 2.5 0 0 0-5 0v1.5Z"/>' +
      '</svg></span>' +
      '<span class="cmux-pen-icon" aria-hidden="true">' +
      '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor">' +
      '<path d="M11.9 1.6a1.5 1.5 0 0 1 2.1 0l.4.4a1.5 1.5 0 0 1 0 2.1l-8 8a1 1 0 0 1-.5.3l-2.8.7a.6.6 0 0 1-.7-.7l.7-2.8a1 1 0 0 1 .3-.5l8-8Zm1.4 1.4-8 8-.4 1.5 1.5-.4 8-8-.4-.4-.7-.7Z"/>' +
      '</svg></span>';

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
      openBlock(element);
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
