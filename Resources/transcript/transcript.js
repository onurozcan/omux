// The transcript view's page. Swift calls omux.setTheme and omux.render; the page posts
// {type: 'open', href}, {type: 'copy', text}, {type: 'changes'}, {type: 'path', path},
// {type: 'agent', id}, {type: 'send', text}, {type: 'quote', text}, {type: 'manage', command}
// and {type: 'config', ...} through the omux handler. render() gets `blocks` as null when the
// conversation didn't change, else {full, total, blocks}: the blocks that changed (or all of
// them), each with a revision. Ids equal positions, so the page keeps them in an array by id.
(function () {
  'use strict';
  const list = document.getElementById('list');
  const cache = new Map();      // block id -> { block, rev, el }
  // What the user opened and where they scrolled, per session: a page shows one session at a
  // time and switches between them, and each should come back as it was left.
  const sessions = new Map();
  let sessionID = null;
  let openRows = new Set();     // tool row ids the user expanded
  let closedRows = new Set();   // rows open by default (errors) the user closed
  let openGroups = new Set();   // tool blocks the user unfolded
  let openThoughts = new Set();
  let fullOutputs = new Set();
  let openForms = new Set();
  let confirming = new Map();   // "blockId:row" -> action awaiting confirmation
  function sessionState(id) {
    let s = sessions.get(id);
    if (!s) { s = { openRows: new Set(), closedRows: new Set(), openGroups: new Set(), openThoughts: new Set(), fullOutputs: new Set(), openForms: new Set(), confirming: new Map(), scrollY: null }; sessions.set(id, s); }
    return s;
  }
  function switchSession(id) {
    if (sessionID !== null) sessionState(sessionID).scrollY = window.scrollY;
    sessionID = id;
    const s = sessionState(id);
    openRows = s.openRows; closedRows = s.closedRows; openGroups = s.openGroups; openThoughts = s.openThoughts;
    fullOutputs = s.fullOutputs; openForms = s.openForms; confirming = s.confirming;
    return s;
  }
  let statusEl = null, agents = [], blocksNow = [], unseen = 0, hasGit = false;
  // While the agent works, queued prompts gather under the Working card as "Up next" instead
  // of sitting in the stream; when it isn't working they show as dashed bubbles in place.
  let nestQueued = false;
  // A long conversation is drawn tail first: the newest blocks now, the rest in idle time above them.
  let pendingBuild = [];   // ids not built yet, ascending
  const pendingSet = new Set();
  let buildTimer = null;
  const eagerCount = 60, chunkSize = 80;
  // Rows the retention cap emptied show their result line and nothing to expand.

  function post(message) {
    try { window.webkit.messageHandlers.omux.postMessage(message); } catch (e) {}
  }
  function esc(s) {
    return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function el(html) {
    const t = document.createElement('template');
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  }
  function nearBottom() {
    return window.innerHeight + window.scrollY >= document.body.scrollHeight - 120;
  }
  function toBottom(smooth) {
    if (smooth && !matchMedia('(prefers-reduced-motion: reduce)').matches && document.body.scrollHeight - (window.innerHeight + window.scrollY) < 1200) {
      window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
    } else {
      window.scrollTo(0, document.body.scrollHeight);
    }
  }

  // MARK: Markdown. No raw HTML from the model, highlighted code, links opened by the app.
  const renderer = {
    html(token) { return esc(token.text || token.raw || ''); },
    code(token) {
      const lang = (token.lang || '').trim().split(/\s+/)[0];
      let body;
      if (lang && hljs.getLanguage(lang)) body = hljs.highlight(token.text, { language: lang }).value;
      else body = esc(token.text);
      return `<pre><button class="copy" type="button">Copy</button><code class="hljs${lang ? ' language-' + esc(lang) : ''}">${body}</code></pre>`;
    },
    link(token) {
      const text = this.parser.parseInline(token.tokens);
      return `<a href="${esc(token.href)}" title="${esc(token.title || '')}">${text}</a>`;
    }
  };
  marked.use({ renderer, gfm: true, breaks: false });

  function markdown(text) {
    try { return marked.parse(text); } catch (e) { return `<p>${esc(text)}</p>`; }
  }

  // Paths like src/app/layout.tsx or ./build.sh:12 become links that open the file preview.
  const pathPattern = /(?<![\w@/.-])((?:\.{1,2}\/|~\/|\/)?(?:[\w.-]+\/)+[\w.-]+\.[A-Za-z0-9]{1,8})(:\d+)?(?![\w/])/g;
  // A note with a link in it, like /remote-control's, gets the link; the rest is plain text.
  function noteHTML(text) {
    return esc(text).replace(/https?:\/\/[^\s<]+/g, (url) => `<a href="${url}">${url}</a>`);
  }

  function linkifyPaths(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const p = node.parentElement;
        if (!p || p.closest('a, pre, .path')) return NodeFilter.FILTER_REJECT;
        return pathPattern.test(node.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const node of nodes) {
      const frag = document.createDocumentFragment();
      let last = 0;
      const text = node.nodeValue;
      pathPattern.lastIndex = 0;
      let m;
      while ((m = pathPattern.exec(text))) {
        frag.appendChild(document.createTextNode(text.slice(last, m.index)));
        const a = document.createElement('span');
        a.className = 'path';
        a.dataset.path = m[1];
        a.textContent = m[0];
        frag.appendChild(a);
        last = m.index + m[0].length;
      }
      frag.appendChild(document.createTextNode(text.slice(last)));
      node.replaceWith(frag);
    }
  }

  function timeOf(ms) {
    if (!ms) return '';
    return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }
  function duration(seconds) {
    const s = Math.round(Math.max(0, seconds));
    if (s < 60) return s + 's';
    if (s < 3600) return Math.floor(s / 60) + 'm ' + (s % 60) + 's';
    return Math.floor(s / 3600) + 'h ' + String(Math.floor(s % 3600 / 60)).padStart(2, '0') + 'm';
  }
  function tokens(n) { return n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n); }
  function shortModel(id) {
    const parts = String(id).split('-');
    const name = parts.slice(1).find(p => !/^\d+$/.test(p)) || parts[1] || id;
    const nums = parts.filter(p => /^\d+$/.test(p)).slice(0, 2).join('.');
    return name.charAt(0).toUpperCase() + name.slice(1) + (nums ? ' ' + nums : '');
  }

  // MARK: Diffs. Lines in common stay grey; removed lines red, added green.
  function lineDiff(oldText, newText) {
    const a = oldText == null ? [] : oldText.split('\n');
    const b = newText == null ? [] : newText.split('\n');
    if (a.length * b.length > 250000) {
      return a.map(l => ['d', l]).concat(b.map(l => ['a', l]));
    }
    const n = a.length, m = b.length;
    const dp = new Array((n + 1) * (m + 1)).fill(0);
    for (let i = n - 1; i >= 0; i--)
      for (let j = m - 1; j >= 0; j--)
        dp[i * (m + 1) + j] = a[i] === b[j] ? dp[(i + 1) * (m + 1) + j + 1] + 1 : Math.max(dp[(i + 1) * (m + 1) + j], dp[i * (m + 1) + j + 1]);
    const out = [];
    let i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) { out.push(['=', a[i]]); i++; j++; }
      else if (dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1]) { out.push(['d', a[i]]); i++; }
      else { out.push(['a', b[j]]); j++; }
    }
    while (i < n) out.push(['d', a[i++]]);
    while (j < m) out.push(['a', b[j++]]);
    return out;
  }
  function diffHTML(row) {
    let lines;
    if (row.unified != null) {
      lines = row.unified.split('\n').map(l => {
        if (l.startsWith('+++') || l.startsWith('---') || l.startsWith('diff ') || l.startsWith('index ')) return ['h', l];
        if (l.startsWith('@@')) return ['h', l];
        if (l.startsWith('+')) return ['a', l.slice(1)];
        if (l.startsWith('-')) return ['d', l.slice(1)];
        return ['=', l.replace(/^ /, '')];
      });
    } else {
      lines = lineDiff(row.old, row.new);
    }
    const cap = 160;
    let html = '';
    lines.slice(0, cap).forEach(([k, l]) => {
      const mark = k === 'a' ? '+' : k === 'd' ? '−' : ' ';
      html += `<div class="${k === 'a' ? 'a' : k === 'd' ? 'd' : k === 'h' ? 'h' : 'c'}"><span class="mark">${mark}</span>${esc(l)}</div>`;
    });
    if (lines.length > cap) html += `<div class="more">${lines.length - cap} more lines</div>`;
    return `<div class="diff">${html}</div>`;
  }
  function diffCounts(row) {
    if (row.unified != null) {
      const ls = row.unified.split('\n');
      return [ls.filter(l => l.startsWith('+') && !l.startsWith('+++')).length, ls.filter(l => l.startsWith('-') && !l.startsWith('---')).length];
    }
    return [row.new == null ? 0 : row.new.split('\n').length, row.old == null ? 0 : row.old.split('\n').length];
  }

  // MARK: Tool rows
  const editTools = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);
  const readTools = new Set(['Read', 'Grep', 'Glob', 'LS', 'Search', 'WebFetch', 'WebSearch']);
  function tagClass(name) {
    if (editTools.has(name)) return 'edit';
    if (name === 'Bash' || name === 'Shell') return 'bash';
    if (readTools.has(name)) return 'read';
    if (name === 'Task') return 'task';
    return 'other';
  }
  function agentFor(row) {
    if (row.name !== 'Task') return null;
    return agents.find(a => a.description === row.detail) || null;
  }
  function rowOpen(row) {
    if (openRows.has(row.id)) return true;
    return row.isError && !!row.output && !closedRows.has(row.id);
  }

  function outputHTML(row) {
    const text = row.output || '';
    let body;
    if (text.length > 5000 && !fullOutputs.has(row.id)) {
      const hidden = text.length - 4500;
      body = esc(text.slice(0, 3000)) + `\n<span class="more-output" data-more="${esc(row.id)}">… ${hidden.toLocaleString()} characters hidden · show all</span>\n` + esc(text.slice(-1500));
    } else {
      body = esc(text);
    }
    const pictures = (row.images || []).map(src => `<img class="result-image" src="${src}" alt="image from ${esc(row.name)}">`).join('');
    return `<div class="output${row.isError ? ' error' : ''}">${pictures ? `<div class="result-images">${pictures}</div>` : ''}${body}</div>`;
  }

  function toolRowHTML(row, block) {
    const tag = tagClass(row.name);
    const hasDiff = row.old != null || row.new != null || row.unified != null;
    const hasOutput = !!row.output || (row.images || []).length > 0;
    const expandable = !row.trimmed && ((hasDiff && row.name !== 'ExitPlanMode') || hasOutput);
    const open = expandable && rowOpen(row);
    const agent = agentFor(row);
    let meta;
    if (agent && !agent.finished) {
      meta = `<span class="running agent" data-agent="${esc(agent.id)}"><span class="${agent.blocked ? 'dot pulse amber' : 'spin'}"></span>${esc(agent.activity)} · ${esc(agent.elapsed)}</span>`;
    } else if (agent) {
      meta = `<span class="meta agent" data-agent="${esc(agent.id)}">done · ${esc(agent.elapsed)} ↗</span>`;
    } else if (row.running) {
      meta = `<span class="running"><span class="spin"></span>Running</span>`;
    } else if (row.trimmed) {
      meta = `<span class="meta${row.isError ? ' error' : ''}" title="Older output was dropped to save memory; the terminal keeps it">${esc(row.result || 'Done')}</span>`;
    } else if (hasDiff && row.name !== 'ExitPlanMode') {
      const [add, del] = diffCounts(row);
      meta = `<span class="meta">${row.line ? `<span class="line">L${row.line}</span>` : ''}<span class="add">+${add}</span><span class="del">−${del}</span></span>` +
             (block.claude && hasGit ? `<span class="changes" data-changes>Changes ↗</span>`
              : row.path ? `<span class="changes" data-open-path="${esc(row.path)}">Open ↗</span>` : '');
    } else {
      meta = `<span class="meta${row.isError ? ' error' : ''}">${esc(row.result || 'Done')}</span>`;
    }
    const chev = expandable ? `<span class="chev">${open ? '▴' : '▾'}</span>` : '';
    const detail = row.name === 'Task' && agent ? row.detail : row.detail || row.name;
    const title = row.path ? ` title="${esc(row.path)}"` : '';
    let html = `<div class="tool${expandable ? ' expandable' : ''}${row.isError ? ' failed' : ''}" data-row="${esc(row.id)}">` +
      `<span class="tag ${tag}">${esc(row.name)}</span>` +
      `<span class="detail"${title}><span>${esc(detail)}</span></span>${meta}${chev}</div>`;
    if (open && hasDiff && row.name !== 'ExitPlanMode') html += diffHTML(row);
    else if (open && hasOutput) html += outputHTML(row);
    return html;
  }

  function toolsHTML(block) {
    const rows = block.tools || [];
    const folded = rows.length > 6 && !openGroups.has(block.id);
    let html = '';
    if (folded) {
      const hidden = rows.length - 3;
      html += `<div class="fold" data-fold>▸ ${hidden} earlier tool call${hidden === 1 ? '' : 's'}</div>`;
      rows.slice(-3).forEach(r => { html += toolRowHTML(r, block); });
    } else {
      if (rows.length > 6) html += `<div class="fold" data-fold>▾ ${rows.length} tool calls</div>`;
      rows.forEach(r => { html += toolRowHTML(r, block); });
    }
    return `<div class="tools" data-block="${block.id}">${html}</div>`;
  }

  function todosHTML(block) {
    const items = block.todos || [];
    const done = items.filter(t => t.status === 'completed').length;
    let html = `<div class="todos-head"><span>Tasks</span><span class="count">${done}/${items.length}</span></div>`;
    for (const t of items) {
      const s = t.status === 'completed' ? 'done' : t.status === 'in_progress' ? 'doing' : 'todo';
      const mark = s === 'done' ? '✓' : s === 'doing' ? '<span class="spin small"></span>' : '';
      html += `<div class="todo ${s}"><span class="box">${mark}</span><span>${esc(t.text)}</span></div>`;
    }
    return `<div class="todos">${html}</div>`;
  }

  function assistantHTML(block) {
    let foot = '';
    if (block.model || block.tokensOut != null) {
      const bits = [];
      if (block.model) bits.push(esc(shortModel(block.model)));
      if (block.tokensIn != null) bits.push('ctx ' + tokens(block.tokensIn));
      if (block.tokensOut != null) bits.push('out ' + tokens(block.tokensOut));
      foot = `<div class="foot"><span>${bits.join(' · ')}</span><span class="actions"><button type="button" data-act="copy">Copy</button></span></div>`;
    } else {
      foot = `<div class="foot"><span></span><span class="actions"><button type="button" data-act="copy">Copy</button></span></div>`;
    }
    return `<div class="assistant"><div class="body">${markdown(block.text)}</div>${foot}</div>`;
  }

  // Queued by Claude Code ("queued"), or sent and not yet confirmed as queued ("queuing").
  function isQueued(b) { return b && b.kind === 'user' && (b.pending === 'queued' || b.pending === 'queuing'); }
  // Claude Code reads its queue between tool calls, so a long tool call is what a queued prompt
  // waits on; Codex only takes its queue once the turn ends.
  let queueReadsMidTurn = false;
  function queueHint() { return queueReadsMidTurn ? 'read once the running tool call returns' : 'sent when the turn ends'; }
  function userHTML(block) {
    if (block.pending === 'removed' || (isQueued(block) && nestQueued)) return `<div class="queued-slot" hidden></div>`;
    const images = (block.images || []).map(src => `<img class="thumb" src="${src}" alt="pasted image">`).join('');
    // A prompt just sent looks like any other prompt; its record replaces it in place when it lands.
    const state = isQueued(block) ? `<div class="pending queued"><span class="dot pulse"></span>Queued · ${queueHint()}</div>` : '';
    return `<div class="user${block.pending && block.pending !== 'sent' ? ' is-pending' : ''}">` +
      `<div class="actions"><button type="button" data-act="quote">Quote</button><button type="button" data-act="resend">Send again</button><button type="button" data-act="copy">Copy</button></div>` +
      `${images ? `<div class="thumbs">${images}</div>` : ''}` +
      `<div class="bubble">${esc(block.text)}</div>${state || (block.time ? `<div class="time">${timeOf(block.time)}</div>` : '')}</div>`;
  }

  function thinkingHTML(block, label) {
    const open = openThoughts.has(block.id);
    const words = block.text.split(/\s+/).length;
    return `<div class="thinking${open ? ' open' : ''}" data-think="${block.id}"><div class="head">${open ? '▾' : '▸'} ${label || 'Thinking'} <span class="count">${words} words</span></div>${open ? `<div class="body">${markdown(block.text)}</div>` : ''}</div>`;
  }

  const actionLabels = { login: 'Sign in', logout: 'Sign out', reconnect: 'Reconnect', remove: 'Remove', enable: 'Enable', disable: 'Disable', uninstall: 'Uninstall' };
  function infoHTML(block) {
    const info = block.info || {};
    const rows = (info.rows || []).map((r, i) => {
      const dot = r.state ? `<span class="dot ${r.state === 'on' ? 'on' : r.state === 'off' ? 'off' : 'ask'}"></span>` : '<span class="dot none"></span>';
      const key = `${block.id}:${i}`;
      const pending = confirming.get(key);
      let actions = '';
      if (pending) {
        actions = `<span class="row-actions confirm">${esc(actionLabels[pending] || pending)}? <button type="button" data-confirm="yes">Yes</button><button type="button" data-confirm="no">No</button></span>`;
      } else if ((r.actions || []).length) {
        actions = `<span class="row-actions">${r.actions.map(a => `<button type="button" data-action="${esc(a)}">${esc(actionLabels[a] || a)}</button>`).join('')}</span>`;
      }
      return `<div class="info-row${actions ? ' has-actions' : ''}" data-i="${i}">${dot}<span class="name">${esc(r.name)}</span><span class="detail" title="${esc(r.detail)}">${esc(r.detail)}</span><span class="note">${esc(r.note)}</span>${actions}</div>`;
    }).join('');
    let form = '';
    if (info.form && openForms.has(block.id)) {
      if (info.form === 'mcp') {
        form = `<form class="info-form" data-form="mcp-add">` +
          `<input name="name" placeholder="name" required pattern="[\\w.-]{1,64}">` +
          `<select name="transport"><option value="stdio">stdio</option><option value="http">http</option><option value="sse">sse</option></select>` +
          `<input name="target" placeholder="command and args, or URL" required class="wide">` +
          `<select name="scope"><option value="user">user</option><option value="local">this project, local</option><option value="project">.mcp.json, shared</option></select>` +
          `<button type="submit">Add</button><button type="button" data-cancel>Cancel</button></form>`;
      } else if (info.form === 'permission') {
        form = `<form class="info-form" data-form="perm-add">` +
          `<select name="kind"><option value="allow">allow</option><option value="deny">deny</option><option value="ask">ask</option></select>` +
          `<input name="rule" placeholder="Bash(npm test:*), Read, WebFetch(domain:example.com)" required class="wide">` +
          `<select name="scope"><option value="user">user</option><option value="project">project</option><option value="local">project, local</option></select>` +
          `<button type="submit">Add</button><button type="button" data-cancel>Cancel</button></form>`;
      }
    }
    const addButton = info.form && !openForms.has(block.id) ? `<button type="button" class="manage" data-add>Add…</button>` : '';
    const extra = info.actionID ? `<button type="button" class="manage" data-info-action="${esc(info.actionID)}">${esc(info.actionLabel || info.actionID)}</button>` : '';
    return `<div class="info" data-info="${block.id}"><div class="info-head"><span class="title">${esc(info.title || '')}</span><span class="summary">${esc(info.summary || '')}</span>${addButton}` +
      `${extra}${info.command ? `<button type="button" class="manage" data-manage="${esc(info.command)}">Manage in terminal ↗</button>` : ''}</div>${form}` +
      `<div class="info-rows">${rows || `<div class="info-empty">${esc(info.empty || 'Nothing configured.')}</div>`}</div></div>`;
  }

  function infoRow(target) {
    const box = target.closest('[data-info]');
    const rowEl = target.closest('.info-row');
    if (!box || !rowEl) return null;
    const blockId = Number(box.dataset.info);
    const entry = cache.get(blockId);
    if (!entry) return null;
    const block = entry.block;
    const i = Number(rowEl.dataset.i);
    return { blockId, block, i, row: (block.info.rows || [])[i] };
  }
  list.addEventListener('submit', e => {
    const form = e.target.closest('form.info-form');
    if (!form) return;
    e.preventDefault();
    const box = form.closest('[data-info]');
    const blockId = Number(box.dataset.info);
    const fields = {};
    new FormData(form).forEach((v, k) => { fields[k] = String(v); });
    post({ type: 'config', action: form.dataset.form, block: blockId, fields });
    openForms.delete(blockId);
    rerender(blockId);
  });

  function blockHTML(block) {
    switch (block.kind) {
      case 'info': return infoHTML(block);
      case 'user': return userHTML(block);
      case 'assistant': return assistantHTML(block);
      case 'thinking': return thinkingHTML(block);
      case 'summary': return thinkingHTML(block, 'Context summary');
      case 'tools': return toolsHTML(block);
      case 'todos': return todosHTML(block);
      case 'note': return `<div class="note">${noteHTML(block.text)}</div>`;
    }
    return '';
  }

  function build(block) {
    const node = el(blockHTML(block) || '<div></div>');
    node.dataset.id = block.id;
    if (block.kind === 'assistant' || block.kind === 'thinking' || block.kind === 'summary') linkifyPaths(node);
    return node;
  }

  // The queue is a strip along the bottom of the chat, so it never narrows the reply.
  // Each item can move up or down or be removed; omux re-queues them in the new order.
  const queuePanel = el(`<aside class="queue-panel" aria-label="Queued prompts"></aside>`);
  document.body.appendChild(queuePanel);
  function renderQueue(queued, editable) {
    const show = queued.length > 0;
    queuePanel.classList.toggle('show', show);
    document.body.classList.toggle('has-queue', show);
    const main = document.querySelector('main');
    if (!show) { if (queuePanel.innerHTML) { queuePanel.innerHTML = ''; main.style.paddingBottom = ''; } return; }
    const items = queued.map((b, i) => `<li data-qid="${b.id}">` +
      `<span class="n">${i + 1}</span>` +
      `<div class="qtext" title="${esc(b.text)}">${esc(b.text.length > 300 ? b.text.slice(0, 300) + '…' : b.text)}</div>` +
      (editable && b.pending === 'queued' ? `<div class="qactions">` +
      `<button type="button" data-q="up" ${i === 0 ? 'disabled' : ''} title="Earlier">↑</button>` +
      `<button type="button" data-q="down" ${i === queued.length - 1 ? 'disabled' : ''} title="Later">↓</button>` +
      `<button type="button" data-q="remove" title="Remove">✕</button></div>` : '') + `</li>`).join('');
    const now = editable && queued.some(b => b.pending === 'queued') ? `<button type="button" class="qnow" data-q="now" data-qid="${queued[0].id}" title="Interrupt the turn and send the queue now (⌃X ⌃S)">Send now</button>` : '';
    const html = `<div class="queue-title"><span class="dot pulse"></span>Up next · ${queued.length}<span class="hint">${queueHint()}, in order</span>${now}</div><ol>${items}</ol>`;
    if (html === queuePanel.innerHTML) return;
    queuePanel.innerHTML = html;
    // Room under the chat so the last lines can scroll above the box.
    main.style.paddingBottom = (queuePanel.offsetHeight + 4) + 'px';
  }
  queuePanel.addEventListener('click', e => {
    const b = e.target.closest('[data-q]');
    if (!b || b.disabled) return;
    post({ type: 'queue', action: b.dataset.q, id: Number(b.closest('[data-qid]').dataset.qid) });
  });

  function statusHTML(s, queued) {
    if (!s) return '';
    switch (s.state) {
      case 'working': {
        // "Thinking" until the first tool call of the turn; then "Working". Dots grow and reset.
        const last = blocksNow.length ? blocksNow[blocksNow.length - 1] : null;
        const verb = last && last.kind === 'tools' ? 'Working' : (last && last.kind === 'user' ? 'Thinking' : 'Working');
        return `<div class="status working"><span class="dot pulse" style="background: var(--blue); margin-top: 5px"></span><div class="grow"><div class="title"><span>${verb}<span class="dots" aria-hidden="true"><i>.</i><i>.</i><i>.</i></span></span><span class="elapsed" data-since="${s.since || ''}"></span></div>${s.detail ? `<div class="detail">${esc(s.detail)}</div>` : ''}${s.live ? `<div class="live">${markdown(s.live)}<span class="caret"></span></div>` : ''}</div></div>`;
      }
      case 'done': {
        const worked = s.workedFor ? `<span class="worked">· worked for ${esc(s.workedFor)}</span>` : '';
        // The reply read off the screen, until its record arrives and takes its place.
        if (s.live) return `<div class="status done"><span class="dot" style="background: var(--green); margin-top: 5px"></span><div class="grow"><div class="title"><span>Done</span>${worked}</div><div class="live">${markdown(s.live)}</div></div></div>`;
        return `<div class="status done"><span class="dot" style="background: var(--green)"></span><span>Done</span>${worked}</div>`;
      }
      case 'blocked':
        return `<div class="status blocked"><span class="dot pulse" style="background: var(--amber)"></span><span>${esc(s.detail ? 'Needs you · ' + s.detail : 'Needs you')}</span><span class="hint">answer in the terminal or type below</span></div>`;
      case 'error':
        return `<div class="status error"><span class="dot" style="background: var(--red)"></span><span>${esc(s.detail ? 'Error · ' + s.detail : 'Error')}</span></div>`;
      case 'stopped':
        return `<div class="status stopped">Stopped · send a message to start it again</div>`;
    }
    return '';
  }

  function tick() {
    document.querySelectorAll('.elapsed[data-since]').forEach(e => {
      const since = Number(e.dataset.since);
      if (since) e.textContent = duration((Date.now() - since) / 1000);
    });
  }

  // MARK: Render. Keyed: only blocks whose data changed are rebuilt.
  let summaryEl = null, summaryNow = '', statusNow = '';
  function summaryHTML(s) {
    if (!s) return '';
    const bits = [];
    if (s.started) bits.push('Started ' + timeOf(s.started));
    bits.push(`${s.turns} turn${s.turns === 1 ? '' : 's'}`);
    if (s.files) bits.push(`${s.files} file${s.files === 1 ? '' : 's'} changed`);
    if (s.tokensOut) bits.push(tokens(s.tokensOut) + ' out');
    if (s.branch) bits.push(`<span class="branch">${esc(s.branch)}</span>`);
    return `<div class="summary">${bits.join('<span class="sep">·</span>')}</div>`;
  }

  function render(payload) {
    const switched = payload.session && payload.session !== sessionID;
    const state = switched ? switchSession(payload.session) : null;
    const stick = switched ? false : nearBottom();
    if (payload.status) queueReadsMidTurn = !!payload.status.queueEditable;
    const update = payload.blocks;
    const blocksChanged = !!update;
    const changedIds = new Set();
    if (blocksChanged) {
      if (update.full) {
        blocksNow = []; cache.forEach(entry => entry.el.remove()); cache.clear();
        pendingBuild = []; pendingSet.clear(); clearTimeout(buildTimer); buildTimer = null;
      }
      for (const block of update.blocks) { blocksNow[block.id] = block; changedIds.add(block.id); }
      if (update.full && update.blocks.length > eagerCount + 30) {
        for (const block of update.blocks.slice(0, update.blocks.length - eagerCount)) { pendingBuild.push(block.id); pendingSet.add(block.id); changedIds.delete(block.id); }
      }
      if (blocksNow.length > update.total) blocksNow.length = update.total;
      // Gaps can't happen (ids are positions), but a hole would break ordering below.
      for (let i = 0; i < blocksNow.length; i++) if (!blocksNow[i]) blocksNow[i] = { id: i, kind: 'note', text: '', rev: 0 };
    }
    const blocks = blocksNow;
    // Queued prompts nest under the Working card; a change of mode redraws them.
    const nestNow = !!(payload.status && (payload.status.state === 'working' || payload.status.state === 'blocked'));
    if (nestNow !== nestQueued) {
      nestQueued = nestNow;
      for (const b of blocks) if (isQueued(b)) { changedIds.add(b.id); const e = cache.get(b.id); if (e) e.rev = -1; }
    }
    const summaryHTMLNow = summaryHTML(payload.summary);
    if (switched || summaryHTMLNow !== summaryNow) {
      summaryNow = summaryHTMLNow;
      if (summaryEl) { summaryEl.remove(); summaryEl = null; }
      if (summaryNow) { summaryEl = el(summaryNow); list.insertBefore(summaryEl, list.firstChild); }
    }
    const agentsJSON = JSON.stringify(payload.agents || []);
    const agentsChanged = agentsJSON !== JSON.stringify(agents);
    agents = payload.agents || [];
    const gitChanged = hasGit !== !!payload.git;
    hasGit = !!payload.git;
    blocksNow = blocks;
    const seen = new Set();
    const stale = blocksChanged || agentsChanged || gitChanged || changedIds.size > 0;
    const noteTop = list.querySelector('.note-top');
    if (!payload.truncated && noteTop) noteTop.remove();
    if (payload.truncated && !noteTop) list.insertBefore(el(`<div class="note note-top">Earlier messages not shown</div>`), summaryEl ? summaryEl.nextSibling : list.firstChild);
    const emptyEl = list.querySelector('.empty');
    const emptyNow = !blocks.length && payload.notice ? payload.notice : '';
    if (emptyEl && emptyEl.dataset.notice !== emptyNow) emptyEl.remove();
    if (emptyNow && (!emptyEl || emptyEl.dataset.notice !== emptyNow)) {
      list.querySelectorAll('[data-id]').forEach(e => e.remove());
      cache.clear();
      list.appendChild(el(`<div class="empty" data-notice="${esc(emptyNow)}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5v8a2.5 2.5 0 0 1-2.5 2.5H9l-4 4v-4h-.5A2.5 2.5 0 0 1 2 13.5"/></svg><div>${esc(payload.notice)}</div></div>`));
    }
    let added = 0;
    if (stale) {
      for (const block of blocks) {
        seen.add(block.id);
        if (pendingSet.has(block.id)) continue;
        let entry = cache.get(block.id);
        const hasAgent = block.kind === 'tools' && (block.tools || []).some(t => t.name === 'Task');
        const redraw = !entry || (changedIds.has(block.id) && entry.rev !== block.rev)
          || (agentsChanged && hasAgent) || (gitChanged && block.kind === 'tools');
        if (redraw) {
          const node = build(block);
          if (entry) {
            // A tool row that just finished gets a brief highlight.
            if (block.kind === 'tools' && entry.block && entry.block.tools) {
              const was = new Set(entry.block.tools.filter(t => t.running).map(t => t.id));
              for (const t of block.tools) if (was.has(t.id) && !t.running) { const el = node.querySelector(`[data-row="${CSS.escape(t.id)}"]`); if (el) el.classList.add('just-done'); }
            }
            entry.el.replaceWith(node);
          } else {
            if (!update || !update.full) node.classList.add('enter');
            list.insertBefore(node, statusEl); added++;
          }
          entry = { block, rev: block.rev, el: node };
          cache.set(block.id, entry);
        } else if (changedIds.has(block.id)) {
          entry.block = block;
        }
      }
      for (const [id, entry] of cache) {
        if (!seen.has(id)) { entry.el.remove(); cache.delete(id); }
      }
      let prev = list.querySelector('.note-top') || summaryEl;
      for (const block of blocks) {
        const entry = cache.get(block.id);
        if (!entry) continue;
        const node = entry.el;
        if (prev ? prev.nextElementSibling !== node : node.parentNode !== list) list.insertBefore(node, prev ? prev.nextElementSibling : list.firstChild);
        prev = node;
      }
      if (pendingBuild.length && !buildTimer) buildTimer = setTimeout(buildPending, 40);
    }
    const queuedNow = blocks.filter(isQueued);
    renderQueue(nestQueued ? queuedNow : [], queueReadsMidTurn);
    const html = statusHTML(payload.status || null, queuedNow) || '';
    if (switched || html !== statusNow || (statusEl && statusEl.parentNode !== list)) {
      statusNow = html;
      if (statusEl) { statusEl.remove(); statusEl = null; }
      if (html) { statusEl = el(html); list.appendChild(statusEl); }
    } else if (statusEl && statusEl !== list.lastElementChild) {
      list.appendChild(statusEl);
    }
    tick();
    if (blocksChanged) renderOutline(blocks);
    if (blocksChanged && update.full) {
      // Not through requestAnimationFrame: a covered or offscreen page may never get a frame.
      const remembered = state && state.scrollY !== null ? state.scrollY : null;
      const place = () => { if (remembered !== null) window.scrollTo(0, remembered); else toBottom(); };
      place();
      setTimeout(() => { place(); post({ type: 'rendered' }); }, 0);
    }
    if (stick) { requestAnimationFrame(() => toBottom(true)); unseen = 0; }
    else if (added) { unseen += added; }
    updateJump();
    if (finder.open) finder.refresh();
  }

  // Builds the next chunk of older blocks above what's shown, keeping the view where it is.
  function buildPending() {
    buildTimer = null;
    if (!pendingBuild.length) return;
    const ids = pendingBuild.splice(Math.max(0, pendingBuild.length - chunkSize));
    const before = document.body.scrollHeight;
    // Only a view right at the end follows it; one scrolled up even a little keeps its place.
    const wasBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 4;
    const first = list.querySelector('[data-id]');
    const frag = document.createDocumentFragment();
    for (const id of ids) {
      pendingSet.delete(id);
      const block = blocksNow[id];
      if (!block) continue;
      const node = build(block);
      cache.set(id, { block, rev: block.rev, el: node });
      frag.appendChild(node);
    }
    list.insertBefore(frag, first || statusEl);
    const grown = document.body.scrollHeight - before;
    // Content was added above: keep the view on what it showed, or at the end if it was there.
    if (wasBottom) toBottom();
    else if (grown > 0) window.scrollTo(0, window.scrollY + grown);
    if (pendingBuild.length) buildTimer = setTimeout(buildPending, 30);
    else { renderOutline(blocksNow); if (finder.open) finder.refresh(); }
  }

  function rerender(blockId) {
    const entry = cache.get(blockId);
    if (!entry) return;
    const node = build(entry.block);
    entry.el.replaceWith(node);
    entry.el = node;
  }

  // MARK: Jump to latest, and the outline of prompts.
  const jump = el(`<button class="jump" type="button">↓ Latest</button>`);
  document.body.appendChild(jump);
  jump.addEventListener('click', () => { toBottom(); unseen = 0; updateJump(); });
  function updateJump() {
    const show = !nearBottom() && document.body.scrollHeight > window.innerHeight + 200;
    jump.classList.toggle('show', show);
    jump.textContent = unseen > 0 ? `↓ ${unseen} new` : '↓ Latest';
  }
  window.addEventListener('scroll', () => { if (nearBottom()) unseen = 0; updateJump(); }, { passive: true });

  const outline = el(`<nav class="outline" aria-label="Prompts"></nav>`);
  document.body.appendChild(outline);
  function renderOutline(blocks) {
    const prompts = blocks.filter(b => b.kind === 'user');
    if (prompts.length < 2) { outline.innerHTML = ''; outline.classList.remove('show'); return; }
    outline.classList.add('show');
    outline.innerHTML = prompts.slice(-40).map(b => `<a data-jump="${b.id}" title="${esc(b.text.slice(0, 120))}"></a>`).join('');
  }
  outline.addEventListener('click', e => {
    const a = e.target.closest('[data-jump]');
    if (!a) return;
    const entry = cache.get(Number(a.dataset.jump));
    if (entry) entry.el.scrollIntoView({ block: 'start', behavior: 'smooth' });
  });

  // MARK: Find in the conversation (⌘F).
  const finder = {
    open: false, matches: [], index: -1,
    bar: el(`<div class="find"><input type="text" placeholder="Find in conversation" aria-label="Find"><span class="count"></span><button type="button" data-prev aria-label="Previous">‹</button><button type="button" data-next aria-label="Next">›</button><button type="button" data-close aria-label="Close">✕</button></div>`),
    show() { this.open = true; this.bar.classList.add('show'); this.bar.querySelector('input').focus(); this.bar.querySelector('input').select(); },
    hide() { this.open = false; this.bar.classList.remove('show'); this.clear(); },
    clear() {
      document.querySelectorAll('mark.hit').forEach(m => m.replaceWith(document.createTextNode(m.textContent)));
      list.normalize(); this.matches = []; this.index = -1; this.bar.querySelector('.count').textContent = '';
    },
    refresh() {
      const q = this.bar.querySelector('input').value.trim().toLowerCase();
      this.clear();
      if (!q) return;
      const walker = document.createTreeWalker(list, NodeFilter.SHOW_TEXT);
      const nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      for (const node of nodes) {
        const text = node.nodeValue, lower = text.toLowerCase();
        let at = lower.indexOf(q);
        if (at < 0) continue;
        const frag = document.createDocumentFragment();
        let last = 0;
        while (at >= 0) {
          frag.appendChild(document.createTextNode(text.slice(last, at)));
          const m = document.createElement('mark'); m.className = 'hit'; m.textContent = text.slice(at, at + q.length);
          frag.appendChild(m); this.matches.push(m);
          last = at + q.length; at = lower.indexOf(q, last);
        }
        frag.appendChild(document.createTextNode(text.slice(last)));
        node.replaceWith(frag);
      }
      this.go(this.matches.length ? 0 : -1);
    },
    go(i) {
      this.matches.forEach(m => m.classList.remove('current'));
      this.index = i;
      this.bar.querySelector('.count').textContent = this.matches.length ? `${i + 1} of ${this.matches.length}` : 'No matches';
      if (i >= 0) { this.matches[i].classList.add('current'); this.matches[i].scrollIntoView({ block: 'center' }); }
    },
    step(d) { if (!this.matches.length) return; this.go((this.index + d + this.matches.length) % this.matches.length); }
  };
  document.body.appendChild(finder.bar);
  finder.bar.querySelector('input').addEventListener('input', () => finder.refresh());
  finder.bar.querySelector('input').addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); finder.step(e.shiftKey ? -1 : 1); }
    if (e.key === 'Escape') { e.preventDefault(); finder.hide(); }
  });
  finder.bar.addEventListener('click', e => {
    if (e.target.closest('[data-prev]')) finder.step(-1);
    if (e.target.closest('[data-next]')) finder.step(1);
    if (e.target.closest('[data-close]')) finder.hide();
  });
  document.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); finder.show(); }
    else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'g') { e.preventDefault(); if (finder.open) finder.step(e.shiftKey ? -1 : 1); }
    else if (e.key === 'Escape') { if (finder.open) finder.hide(); else post({ type: 'interrupt' }); }
  });

  // MARK: Clicks
  function blockOf(target) {
    const node = target.closest('[data-id]');
    if (!node) return null;
    const entry = cache.get(Number(node.dataset.id));
    return entry ? entry.block : null;
  }
  list.addEventListener('click', e => {
    const copy = e.target.closest('.copy');
    if (copy) {
      const code = copy.parentElement.querySelector('code');
      post({ type: 'copy', text: code ? code.textContent : '' });
      copy.textContent = 'Copied';
      setTimeout(() => { copy.textContent = 'Copy'; }, 1200);
      return;
    }
    const act = e.target.closest('[data-act]');
    if (act) {
      const block = blockOf(act);
      if (!block) return;
      if (act.dataset.act === 'copy') { post({ type: 'copy', text: block.text }); act.textContent = 'Copied'; setTimeout(() => { act.textContent = 'Copy'; }, 1200); }
      if (act.dataset.act === 'resend') post({ type: 'send', text: block.text });
      if (act.dataset.act === 'quote') post({ type: 'quote', text: block.text });
      return;
    }
    const link = e.target.closest('a[href]');
    if (link) { e.preventDefault(); post({ type: 'open', href: link.getAttribute('href') }); return; }
    const path = e.target.closest('.path');
    if (path) { post({ type: 'path', path: path.dataset.path }); return; }
    const agent = e.target.closest('[data-agent]');
    if (agent) { e.stopPropagation(); post({ type: 'agent', id: agent.dataset.agent }); return; }
    if (e.target.closest('[data-changes]')) { e.stopPropagation(); post({ type: 'changes' }); return; }
    const more = e.target.closest('[data-more]');
    if (more) { fullOutputs.add(more.dataset.more); const blockId = Number(more.closest('.tools').dataset.block); rerender(blockId); return; }
    const manage = e.target.closest('[data-manage]');
    if (manage) { post({ type: 'manage', command: manage.dataset.manage }); return; }
    const add = e.target.closest('[data-add]');
    if (add) { const id = Number(add.closest('[data-info]').dataset.info); openForms.add(id); rerender(id); return; }
    const infoAction = e.target.closest('[data-info-action]');
    if (infoAction) { post({ type: 'config', action: infoAction.dataset.infoAction, block: Number(infoAction.closest('[data-info]').dataset.info) }); return; }
    const cancel = e.target.closest('form.info-form [data-cancel]');
    if (cancel) { const id = Number(cancel.closest('[data-info]').dataset.info); openForms.delete(id); rerender(id); return; }
    const rowAction = e.target.closest('[data-action]');
    if (rowAction) {
      const hit = infoRow(rowAction);
      if (!hit || !hit.row) return;
      const action = rowAction.dataset.action;
      const key = `${hit.blockId}:${hit.i}`;
      if (action === 'remove' || action === 'uninstall' || action === 'disable') { confirming.set(key, action); rerender(hit.blockId); return; }
      post(configMessage(hit, action));
      return;
    }
    const confirm = e.target.closest('[data-confirm]');
    if (confirm) {
      const hit = infoRow(confirm);
      if (!hit) return;
      const key = `${hit.blockId}:${hit.i}`;
      const action = confirming.get(key);
      confirming.delete(key);
      if (confirm.dataset.confirm === 'yes' && action) post(configMessage(hit, action));
      rerender(hit.blockId);
      return;
    }
    const openPath = e.target.closest('[data-open-path]');
    if (openPath) { e.stopPropagation(); post({ type: 'path', path: openPath.dataset.openPath }); return; }
    const think = e.target.closest('.thinking');
    if (think) {
      const id = Number(think.dataset.think);
      if (openThoughts.has(id)) openThoughts.delete(id); else openThoughts.add(id);
      rerender(id);
      return;
    }
    const tools = e.target.closest('.tools');
    if (!tools) return;
    const blockId = Number(tools.dataset.block);
    const fold = e.target.closest('[data-fold]');
    if (fold) {
      if (openGroups.has(blockId)) openGroups.delete(blockId); else openGroups.add(blockId);
      rerender(blockId);
      return;
    }
    const row = e.target.closest('.tool.expandable');
    if (row) {
      const id = row.dataset.row;
      const wasOpen = row.querySelector('.chev') && row.querySelector('.chev').textContent === '▴';
      if (wasOpen) { openRows.delete(id); closedRows.add(id); } else { openRows.add(id); closedRows.delete(id); }
      rerender(blockId);
    }
  });

  function configMessage(hit, action) {
    const kind = hit.block.info.kind || '';
    const row = hit.row;
    if (kind === 'mcp') return { type: 'config', action: 'mcp-' + action, block: hit.blockId, name: row.name, arg: row.arg };
    if (kind === 'plugins') return { type: 'config', action: 'plugin-' + action, block: hit.blockId, name: row.name, arg: row.arg };
    if (kind === 'permissions') return { type: 'config', action: 'perm-' + action, block: hit.blockId, kind: row.name, rule: row.detail, arg: row.arg };
    return { type: 'config', action, block: hit.blockId, name: row.name, arg: row.arg };
  }

  function setTheme(theme) {
    const root = document.documentElement.style;
    if (theme.bg) root.setProperty('--bg', theme.bg);
    if (theme.fg) root.setProperty('--fg', theme.fg);
    if (theme.accent) {
      root.setProperty('--accent', theme.accent);
      root.setProperty('--accent-soft', theme.accentSoft || theme.accent);
    }
    if (theme.mono) root.setProperty('--mono', theme.mono);
    if (theme.font) root.setProperty('--font', theme.font);
    if (theme.size) root.setProperty('--size', theme.size + 'px');
    const body = document.body.classList;
    ['width-wide', 'width-narrow', 'compact', 'bubbles-outline', 'bubbles-plain', 'no-times'].forEach(c => body.remove(c));
    if (theme.width === 'wide' || theme.width === 'narrow') body.add('width-' + theme.width);
    if (theme.density === 'compact') body.add('compact');
    if (theme.bubbles === 'outline' || theme.bubbles === 'plain') body.add('bubbles-' + theme.bubbles);
    if (theme.timestamps === false) body.add('no-times');
    const dark = theme.dark !== false;
    document.documentElement.classList.toggle('light', !dark);
    document.getElementById('hl-dark').disabled = !dark;
    document.getElementById('hl-light').disabled = dark;
    root.setProperty('--muted', dark ? '#8d8d93' : '#6b6b70');
    root.setProperty('--faint', dark ? '#6f6f75' : '#8a8a90');
  }

  setInterval(tick, 1000);
  window.omux = { render, setTheme, toBottom, find: () => finder.show() };
})();
