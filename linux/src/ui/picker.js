(function () {
  if (window.__omuxPick) window.__omuxPick.stop();
  const box = document.createElement('div');
  const tag = document.createElement('div');
  box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #22d3ee;background:rgba(34,211,238,0.12);border-radius:2px;display:none';
  tag.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;background:#22d3ee;color:#0b0b0f;font:11px ui-monospace,Menlo,monospace;padding:2px 6px;border-radius:3px;display:none';
  document.documentElement.append(box, tag);
  const name = (el) => {
    let s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    const cls = [...el.classList].filter((c) => !c.includes(':')).slice(0, 3);
    if (cls.length) s += '.' + cls.join('.');
    return s;
  };
  const path = (el) => {
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && parts.length < 4; n = n.parentElement) {
      if ((n === document.body || n === document.documentElement) && parts.length) break;
      parts.unshift(name(n));
      if (n.id) break;
    }
    return parts.join(' > ');
  };
  let current = null;
  const move = (e) => {
    const el = e.target;
    if (!(el instanceof Element)) return;
    current = el;
    const r = el.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
    tag.textContent = name(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
    Object.assign(tag.style, { display: 'block', left: Math.max(0, r.left) + 'px', top: Math.max(0, r.top - 20) + 'px' });
  };
  const PROPS = ['display', 'position', 'box-sizing', 'width', 'height', 'margin', 'padding', 'border', 'border-radius',
    'background-color', 'background-image', 'color', 'font-family', 'font-size', 'font-weight', 'line-height',
    'letter-spacing', 'text-align', 'gap', 'flex-direction', 'justify-content', 'align-items',
    'grid-template-columns', 'box-shadow', 'opacity', 'overflow'];
  const pick = (e) => {
    e.preventDefault();
    e.stopPropagation();
    const el = current || e.target;
    const cs = getComputedStyle(el);
    const css = PROPS.map((p) => p + ': ' + cs.getPropertyValue(p))
      .filter((l) => !/: (normal|none|auto|0px|static|visible|)$/.test(l)).join(';\n');
    const r = el.getBoundingClientRect();
    stop();
    window.webkit.messageHandlers.omuxPick.postMessage({
      selector: path(el), html: el.outerHTML.slice(0, 30000), css, url: location.href,
      x: r.left, y: r.top, width: r.width, height: r.height });
  };
  const block = (e) => { e.preventDefault(); e.stopPropagation(); };
  const key = (e) => {
    if (e.key !== 'Escape') return;
    stop();
    window.webkit.messageHandlers.omuxPick.postMessage({ cancel: true });
  };
  function stop() {
    document.removeEventListener('mousemove', move, true);
    document.removeEventListener('click', pick, true);
    document.removeEventListener('mousedown', block, true);
    document.removeEventListener('mouseup', block, true);
    document.removeEventListener('keydown', key, true);
    box.remove();
    tag.remove();
    window.__omuxPick = null;
  }
  document.addEventListener('mousemove', move, true);
  document.addEventListener('click', pick, true);
  document.addEventListener('mousedown', block, true);
  document.addEventListener('mouseup', block, true);
  document.addEventListener('keydown', key, true);
  window.__omuxPick = { stop };
})();
