// The Files panel's editor page: a textarea over a highlighted copy of the same text, kept in
// sync, so editing is native (undo, selection, dictation) and the colors come from highlight.js.
// Swift calls editor.load, editor.replace, editor.setWrap, editor.setTheme and editor.markSaved;
// the page posts {type: 'ready'}, {type: 'dirty', dirty} and {type: 'save', text}.
(function () {
  'use strict';
  const scroller = document.getElementById('scroller');
  const gutter = document.getElementById('gutter');
  const stack = document.getElementById('stack');
  const layer = document.getElementById('layer');
  const code = document.getElementById('code');
  const input = document.getElementById('input');
  let language = null, saved = '', indent = '  ', highlightTimer = null, lines = 0, activeLine = 0;
  const bar = document.createElement('div');
  bar.className = 'current';
  stack.insertBefore(bar, input);
  // Highlighting past this many characters is skipped; the text stays editable, in one color.
  const highlightLimit = 300000;

  function post(message) {
    try { window.webkit.messageHandlers.omux.postMessage(message); } catch (e) {}
  }
  function esc(s) {
    return s.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  }

  function detectIndent(text) {
    if (/\n\t/.test(text)) return '\t';
    const m = text.match(/\n( +)\S/);
    if (m) return m[1].length >= 4 ? '    ' : '  ';
    return '  ';
  }

  function paint() {
    const text = input.value;
    const plain = text.length > highlightLimit;
    document.body.classList.toggle('plain', plain);
    if (!plain) {
      let html;
      if (language && hljs.getLanguage(language)) {
        try { html = hljs.highlight(text, { language, ignoreIllegals: true }).value; } catch (e) { html = esc(text); }
      } else {
        html = esc(text);
      }
      // A trailing newline needs a visible line, or the textarea grows past the layer.
      code.innerHTML = html + (text.endsWith('\n') ? ' ' : '');
    }
    fit();
    numbers(text);
  }

  function schedulePaint() {
    clearTimeout(highlightTimer);
    const wait = input.value.length > 50000 ? 120 : 30;
    highlightTimer = setTimeout(paint, wait);
  }

  function fit() {
    // The textarea sizes to its own content; the layer sits behind it at the same size.
    input.style.height = 'auto';
    input.style.height = input.scrollHeight + 'px';
    stack.style.height = input.scrollHeight + 'px';
    if (!document.body.classList.contains('wrap')) {
      input.style.width = 'auto';
      const width = Math.max(input.scrollWidth, scroller.clientWidth - gutter.offsetWidth);
      input.style.width = width + 'px';
      stack.style.width = width + 'px';
    } else {
      input.style.width = '';
      stack.style.width = '';
    }
  }

  function numbers(text) {
    const count = text.split('\n').length;
    if (count !== lines) {
      lines = count;
      let html = '';
      for (let i = 1; i <= count; i++) html += `<span>${i}</span>\n`;
      gutter.innerHTML = html;
      activeLine = 0;
    }
    caretLine();
  }

  // The line the caret is on: its number lit in the gutter, a bar behind it in the text.
  function caretLine() {
    const line = input.value.slice(0, input.selectionStart).split('\n').length;
    if (line === activeLine) return;
    const spans = gutter.children;
    if (spans[activeLine - 1]) spans[activeLine - 1].classList.remove('active');
    if (spans[line - 1]) spans[line - 1].classList.add('active');
    activeLine = line;
    const style = getComputedStyle(input);
    const lh = parseFloat(style.lineHeight) || 0, pad = parseFloat(style.paddingTop) || 0;
    bar.style.top = (pad + (line - 1) * lh) + 'px';
    bar.style.height = lh + 'px';
    bar.style.display = document.body.classList.contains('wrap') ? 'none' : '';
  }
  document.addEventListener('selectionchange', () => { if (document.activeElement === input) caretLine(); });
  input.addEventListener('keyup', caretLine);
  input.addEventListener('click', caretLine);
  input.addEventListener('focus', caretLine);

  function markDirty() {
    post({ type: 'dirty', dirty: input.value !== saved });
  }

  input.addEventListener('input', () => { schedulePaint(); markDirty(); });
  input.addEventListener('scroll', () => { input.scrollTop = 0; input.scrollLeft = 0; });

  input.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
      e.preventDefault();
      post({ type: 'save', text: input.value });
      return;
    }
    if (e.key === 'Tab') {
      e.preventDefault();
      const start = input.selectionStart, end = input.selectionEnd, value = input.value;
      if (start === end && !e.shiftKey) {
        input.setRangeText(indent, start, end, 'end');
      } else {
        // Indent or outdent every selected line.
        const lineStart = value.lastIndexOf('\n', start - 1) + 1;
        const block = value.slice(lineStart, end);
        const changed = e.shiftKey
          ? block.replace(/^(\t| {1,4})/gm, '')
          : block.replace(/^/gm, indent);
        input.setRangeText(changed, lineStart, end, 'select');
      }
      input.dispatchEvent(new Event('input'));
      return;
    }
    if (e.key === 'Enter' && !e.metaKey && !e.ctrlKey && !e.altKey) {
      // Keep the previous line's indentation.
      const start = input.selectionStart;
      const lineStart = input.value.lastIndexOf('\n', start - 1) + 1;
      const lead = input.value.slice(lineStart, start).match(/^[ \t]*/)[0];
      if (lead) {
        e.preventDefault();
        input.setRangeText('\n' + lead, start, input.selectionEnd, 'end');
        input.dispatchEvent(new Event('input'));
      }
    }
  });

  window.addEventListener('resize', fit);

  function load(doc) {
    language = doc.language || null;
    saved = doc.text || '';
    indent = detectIndent(saved);
    document.body.classList.toggle('wrap', !!doc.wrap);
    gutter.classList.toggle('hidden', !!doc.wrap);
    input.value = saved;
    lines = 0;
    paint();
    scroller.scrollTop = 0;
    post({ type: 'dirty', dirty: false });
  }

  /// New contents from disk; the caret and scroll stay where they can.
  function replace(doc) {
    const top = scroller.scrollTop, pos = input.selectionStart;
    saved = doc.text || '';
    input.value = saved;
    paint();
    scroller.scrollTop = top;
    try { input.setSelectionRange(Math.min(pos, saved.length), Math.min(pos, saved.length)); } catch (e) {}
    post({ type: 'dirty', dirty: false });
  }

  function markSaved() {
    saved = input.value;
    post({ type: 'dirty', dirty: false });
  }

  function setWrap(wrap) {
    document.body.classList.toggle('wrap', !!wrap);
    gutter.classList.toggle('hidden', !!wrap);
    fit();
    activeLine = 0;
    caretLine();
  }

  function setTheme(theme) {
    const root = document.documentElement.style;
    if (theme.bg) root.setProperty('--bg', theme.bg);
    if (theme.fg) root.setProperty('--fg', theme.fg);
    if (theme.accent) root.setProperty('--accent', theme.accent);
    if (theme.mono) root.setProperty('--mono', theme.mono);
    if (theme.size) root.setProperty('--size', theme.size + 'px');
    const dark = theme.dark !== false;
    document.getElementById('hl-dark').disabled = !dark;
    document.getElementById('hl-light').disabled = dark;
    root.setProperty('--muted', dark ? '#8d8d93' : '#6b6b70');
    fit();
  }

  function focus() { input.focus(); }
  function text() { return input.value; }

  window.editor = { load, replace, markSaved, setWrap, setTheme, focus, text };
  post({ type: 'ready' });
})();
