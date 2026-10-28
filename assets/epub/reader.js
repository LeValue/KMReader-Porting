'use strict';
(() => {
  let book, rendition, config, preferences, location, auxiliary, anchor;
  let restoring = true, disposed = false, userMove = false, relocationTimer, resizeTimer;
  const tick = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const send = (type, value = {}) => {
    if (disposed || !config) return;
    const message = {type, ...value, nonce: config.nonce};
    if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('readerEvent', message);
    else window.dispatchEvent(new CustomEvent('readerEvent', {detail: message}));
  };
  const timeout = (promise, ms = 6000) => Promise.race([promise, new Promise(resolve => setTimeout(resolve, ms))]);
  const colors = () => preferences.theme === 'black' ? ['#1c1c1e', '#e8e4dc'] : preferences.theme === 'white' ? ['#ffffff', '#262321'] : ['#efe5d0', '#262321'];
  function style(document) {
    const [background, foreground] = colors();
    let head = document.head || document.querySelector('head');
    if (!head) { head = document.createElementNS('http://www.w3.org/1999/xhtml', 'head'); document.documentElement.prepend(head); }
    let sheet = document.getElementById('kmreader-preferences');
    if (!sheet) { sheet = document.createElementNS('http://www.w3.org/1999/xhtml', 'style'); sheet.id = 'kmreader-preferences'; head.appendChild(sheet); }
    const custom = preferences.fontUrl && new URL(preferences.fontUrl).origin === window.location.origin;
    const family = custom ? 'font-family:kmreader-custom !important;' : ['serif','sans-serif'].includes(preferences.font) ? `font-family:${preferences.font} !important;` : '';
    const face = custom ? `@font-face{font-family:kmreader-custom;src:url("${preferences.fontUrl}");font-display:block;}` : '';
    const align = ['left', 'right', 'justify', 'center'].includes(preferences.alignment) ? `text-align:${preferences.alignment} !important;` : '';
    sheet.textContent = `${face}html,body{background:${background} !important;color:${foreground} !important;}
      body{font-size:${preferences.fontSize}px !important;line-height:${preferences.lineHeight} !important;${family}${align}}
      p{margin-block-end:${preferences.paragraphSpacing}em !important;text-indent:${preferences.indent}em !important;}
      body{letter-spacing:${preferences.letterSpacing}em !important;word-spacing:${preferences.wordSpacing}em !important;}
      img,svg,video{max-width:100% !important;object-fit:contain;}a{color:${preferences.theme === 'black' ? '#9fc6ff' : '#235a9c'};}`;
  }
  async function stable(contents) {
    await tick();
    await timeout(Promise.all(contents.map(async content => {
      const doc = content.document || content;
      if (doc.fonts) await doc.fonts.ready;
      await Promise.all([...doc.images].map(image => image.complete ? Promise.resolve() : new Promise(resolve => {
        image.addEventListener('load', resolve, {once: true}); image.addEventListener('error', resolve, {once: true});
      })));
    })));
    await tick();
  }
  const textIndexes = new WeakMap();
  function textIndex(contents) {
    const doc = contents.document;
    if (textIndexes.has(doc)) return textIndexes.get(doc);
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    const nodes = [], offsets = new WeakMap(); let length = 0, node;
    while ((node = walker.nextNode())) {
      if (['STYLE', 'SCRIPT'].includes(node.parentElement.tagName)) continue;
      offsets.set(node, length); nodes.push(node); length += node.length;
    }
    const index = {nodes, offsets, length}; textIndexes.set(doc, index); return index;
  }
  function progression(start, displayed) {
    for (const contents of rendition.getContents()) {
      if (contents.sectionIndex !== start.index) continue;
      try {
        const index = textIndex(contents), range = contents.range(start.cfi);
        const offset = index.offsets.get(range.startContainer);
        if (index.length && offset !== undefined) return Math.min(1, (offset + range.startOffset) / index.length);
      } catch (_) { /* Image-only sections use their page position. */ }
    }
    return Math.max(0, (displayed.page - 1) / Math.max(1, displayed.total));
  }
  function position(changed = false) {
    if (!location || restoring || auxiliary) return;
    const start = location.start, displayed = start.displayed || {page: 1, total: 1};
    if (changed) anchor = start.cfi;
    send('position', {cfi: start.cfi, href: start.href, page: displayed.page, pages: displayed.total,
      progression: progression(start, displayed),
      totalProgression: Number.isFinite(start.percentage) ? start.percentage : null,
      atStart: !!location.atStart, atEnd: !!location.atEnd, changed});
  }
  function hook(contents) {
    const section = book.spine.get(contents.sectionIndex);
    const doc = contents.document;
    if (!doc.documentElement.lang && config.language) doc.documentElement.lang = config.language;
    if (!doc.documentElement.dir && config.direction === 'rtl') doc.documentElement.dir = 'rtl';
    style(doc);
    doc.addEventListener('click', event => {
      const link = event.target.closest && event.target.closest('a[href]');
      if (link) {
        event.preventDefault(); event.stopImmediatePropagation();
        send('link', {href: link.href, base: section.href});
      } else if (doc.getSelection().isCollapsed) {
        const bounds = doc.defaultView.frameElement.getBoundingClientRect();
        send('tap', {x: (bounds.left + event.clientX) / window.innerWidth, y: (bounds.top + event.clientY) / window.innerHeight});
      }
    }, true);
    doc.addEventListener('keydown', event => {
      if (event.ctrlKey || event.metaKey || event.altKey || !doc.getSelection().isCollapsed) return;
      const rtl = config.direction === 'rtl';
      if ([rtl ? 'ArrowLeft' : 'ArrowRight', 'PageDown', ' '].includes(event.key)) {
        event.preventDefault(); send('turn', {delta: 1});
      } else if ([rtl ? 'ArrowRight' : 'ArrowLeft', 'PageUp'].includes(event.key)) {
        event.preventDefault(); send('turn', {delta: -1});
      } else if (event.key === 'Escape') send('close');
    });
    let touch;
    doc.addEventListener('touchstart', event => {
      touch = event.touches.length === 1 ? {x: event.touches[0].clientX, y: event.touches[0].clientY, time: Date.now()} : null;
      if (!restoring) userMove = true;
    }, {passive: true});
    doc.addEventListener('touchend', event => {
      if (!touch || preferences.flow === 'scrolled' || !doc.getSelection().isCollapsed) return;
      const end = event.changedTouches[0];
      const dx = end.clientX - touch.x, dy = end.clientY - touch.y;
      if (Math.abs(dx) > 45 && Math.abs(dx) > Math.abs(dy) * 1.3 && Date.now() - touch.time < 1000) {
        event.preventDefault(); send('turn', {delta: dx < 0 !== (config.direction === 'rtl') ? 1 : -1});
      }
      touch = null;
    }, {passive: false});
    doc.addEventListener('wheel', () => { if (!restoring) userMove = true; }, {passive: true});
    for (const image of doc.images) image.addEventListener('load', () => {
      if (!restoring && location) preserve(() => Promise.resolve());
    });
    if (doc.fonts) doc.fonts.addEventListener('loadingdone', () => { if (!restoring && location) preserve(() => Promise.resolve()); });
    doc.addEventListener('selectionchange', () => {
      const selection = doc.getSelection();
      if (!selection.isCollapsed && selection.toString().trim()) send('selection', {text: selection.toString().slice(0, 16000)});
    });
  }
  async function preserve(change) {
    if (!rendition) return;
    const cfi = anchor || (location && location.start.cfi);
    restoring = true; userMove = false; clearTimeout(relocationTimer);
    try {
      await change();
      await stable(rendition.getContents());
      if (cfi) await rendition.display(cfi);
      await tick();
    } finally { restoring = false; position(false); }
  }
  function setPreferences(value) {
    preferences = value;
    const [background] = colors();
    document.body.style.background = background;
    document.getElementById('viewer').style.background = background;
    return preserve(async () => {
      rendition.flow(value.flow === 'scrolled' ? 'scrolled-doc' : 'paginated');
      rendition.spread(value.columns === 1 ? 'none' : value.columns === 2 ? 'always' : 'auto', 800);
      rendition.settings.gap = value.margin * 2;
      for (const contents of rendition.getContents()) style(contents.document);
      if (auxiliary) style(auxiliary.contentDocument);
      await rendition.resize(window.innerWidth, window.innerHeight);
    });
  }
  async function next() {
    if (!rendition || restoring || auxiliary) return;
    if (location && location.atEnd) { send('end'); return; }
    restoring = true;
    try { await rendition.next(); await stable(rendition.getContents()); }
    finally { restoring = false; userMove = false; position(true); }
  }
  async function previous() {
    if (!rendition || restoring || auxiliary) return;
    restoring = true;
    try { await rendition.prev(); await stable(rendition.getContents()); }
    finally { restoring = false; userMove = false; position(true); }
  }
  async function display(target, changed = true) {
    if (auxiliary) closeAuxiliary();
    restoring = true;
    try { await rendition.display(target); await stable(rendition.getContents()); }
    finally { restoring = false; userMove = false; position(changed); }
  }
  async function legacyProgress(progression) {
    const contents = rendition.getContents()[0];
    if (!contents || progression <= 0) return;
    const walker = contents.document.createTreeWalker(contents.document.body, NodeFilter.SHOW_TEXT);
    const nodes = []; let total = 0, node;
    while ((node = walker.nextNode())) { nodes.push(node); total += node.length; }
    let remaining = Math.floor(total * Math.min(.999999, progression));
    for (const text of nodes) {
      if (remaining <= text.length) {
        const range = contents.document.createRange(); range.setStart(text, remaining); range.collapse(true);
        await rendition.display(contents.cfiFromRange(range)); return;
      }
      remaining -= text.length;
    }
  }
  async function open(value) {
    config = value; preferences = value.preferences; restoring = true;
    document.body.style.background = colors()[0];
    document.getElementById('viewer').style.background = colors()[0];
    book = ePub(value.url, {openAs: 'opf', replacements: 'none'});
    await book.ready;
    rendition = book.renderTo('viewer', {width: '100%', height: '100%',
      flow: preferences.flow === 'scrolled' ? 'scrolled-doc' : 'paginated',
      spread: preferences.columns === 1 ? 'none' : preferences.columns === 2 ? 'always' : 'auto',
      minSpreadWidth: 800, gap: preferences.margin * 2, direction: value.direction,
      allowScriptedContent: false, allowPopups: false});
    rendition.hooks.content.register(hook);
    rendition.on('relocated', value => {
      location = value;
      clearTimeout(relocationTimer);
      relocationTimer = setTimeout(() => { const changed = userMove; userMove = false; position(changed); }, 120);
    });
    rendition.on('displayError', error => { if (!restoring) send('error', {message: String(error)}); });
    let restoredCfi = Boolean(value.cfi);
    try { await rendition.display(value.cfi || value.href || undefined); }
    catch (error) {
      if (!value.cfi) throw error;
      restoredCfi = false;
      await rendition.display(value.href || undefined);
    }
    await stable(rendition.getContents());
    if (!restoredCfi && value.progression > 0) await legacyProgress(value.progression);
    await tick(); restoring = false; userMove = false; anchor = restoredCfi ? value.cfi : (location && location.start.cfi);
    position(false); send('ready');
    window.addEventListener('resize', () => {
      restoring = true;
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => preserve(() => rendition.resize(window.innerWidth, window.innerHeight)), 150);
    });
  }
  async function search(term) {
    const matches = [];
    for (const section of book.spine.spineItems) {
      if (section.linear === 'no') continue;
      await section.load(book.load.bind(book));
      for (const result of section.find(term)) {
        matches.push({cfi: result.cfi, excerpt: result.excerpt, href: section.href});
        if (matches.length >= 500) break;
      }
      section.unload();
      if (matches.length >= 500) break;
    }
    return matches;
  }
  function closeAuxiliary() {
    if (!auxiliary) return;
    auxiliary.remove(); auxiliary = null;
    send('auxiliary', {active: false});
  }
  async function openAuxiliary(url) {
    closeAuxiliary();
    auxiliary = document.createElement('iframe'); auxiliary.id = 'auxiliary';
    auxiliary.sandbox = 'allow-same-origin'; auxiliary.style.display = 'block';
    auxiliary.src = url; document.body.appendChild(auxiliary);
    await new Promise(resolve => { auxiliary.onload = resolve; });
    style(auxiliary.contentDocument);
    auxiliary.contentDocument.addEventListener('click', event => {
      const link = event.target.closest && event.target.closest('a[href]');
      if (link) { event.preventDefault(); send('link', {href: link.href}); }
    }, true);
    send('auxiliary', {active: true});
  }
  window.reader = {open, next, previous, display, preferences: setPreferences, search, openAuxiliary, closeAuxiliary,
    position: () => location, destroy: () => { disposed = true; clearTimeout(relocationTimer); clearTimeout(resizeTimer); if (rendition) rendition.destroy(); if (book) book.destroy(); }};
})();
