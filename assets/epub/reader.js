'use strict';
(() => {
  let book, rendition, config, preferences, location, auxiliary, anchor;
  let renditionSpineHooks = [], preferenceQueue = Promise.resolve();
  let userMoveUntil = 0;
  let restoring = true, disposed = false, userMove = false, relocationTimer, resizeTimer = null, layoutJobs = 0;
  const tick = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const inputEvents = ['wheel', 'touchstart', 'touchmove'];
  const noteUserMove = () => { if (!restoring && !disposed) { userMove = true; userMoveUntil = Date.now() + 2000; } };
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
    changed = changed && start.cfi !== anchor;
    if (changed) {
      anchor = start.cfi;
      if (preferences.flow === 'scrolled') userMoveUntil = Date.now() + 2000;
    }
    send('position', {cfi: start.cfi, href: start.href, page: displayed.page, pages: displayed.total,
      progression: progression(start, displayed),
      totalProgression: Number.isFinite(start.percentage) ? start.percentage : null,
      atStart: !!location.atStart, atEnd: !!location.atEnd, changed});
  }
  function hook(contents) {
    const section = book.spine.get(contents.sectionIndex);
    const doc = contents.document;
    const active = () => doc.defaultView && doc.defaultView.frameElement && doc.defaultView.frameElement.isConnected;
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
      noteUserMove();
    }, {passive: true});
    doc.addEventListener('touchmove', noteUserMove, {passive: true});
    doc.addEventListener('touchend', event => {
      if (!touch || preferences.flow === 'scrolled' || !doc.getSelection().isCollapsed) return;
      const end = event.changedTouches[0];
      const dx = end.clientX - touch.x, dy = end.clientY - touch.y;
      if (Math.abs(dx) > 45 && Math.abs(dx) > Math.abs(dy) * 1.3 && Date.now() - touch.time < 1000) {
        event.preventDefault(); send('turn', {delta: dx < 0 !== (config.direction === 'rtl') ? 1 : -1});
      }
      touch = null;
    }, {passive: false});
    doc.addEventListener('wheel', noteUserMove, {passive: true});
    for (const image of doc.images) image.addEventListener('load', () => {
      if (active() && !restoring && location) preserve(() => Promise.resolve());
    });
    if (doc.fonts) doc.fonts.addEventListener('loadingdone', () => { if (active() && !restoring && location) preserve(() => Promise.resolve()); });
    doc.addEventListener('selectionchange', () => {
      const selection = doc.getSelection();
      if (!selection.isCollapsed && selection.toString().trim()) send('selection', {text: selection.toString().slice(0, 16000)});
    });
  }
  async function waitForLayout() {
    const deadline = Date.now() + 10000;
    while (restoring || resizeTimer !== null || layoutJobs > 0) {
      if (disposed) return;
      if (Date.now() > deadline) throw new Error('The EPUB layout did not settle.');
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
  async function preserve(change) {
    if (!rendition) return;
    const cfi = anchor || (location && location.start.cfi);
    layoutJobs++; restoring = true; userMove = false; userMoveUntil = 0; clearTimeout(relocationTimer);
    try {
      await change();
      await stable(rendition.getContents());
      if (cfi) await displayStable(cfi);
      await tick();
    } finally { layoutJobs--; restoring = layoutJobs > 0; position(false); }
  }
  function setPreferences(value) {
    // Flow changes replace the manager. Keep rapid preference updates ordered
    // so an older reflow cannot destroy a newer rendition or restore its CFI.
    const pending = preferenceQueue.then(() => applyPreferences(value));
    preferenceQueue = pending.catch(() => {});
    return pending;
  }
  async function applyPreferences(value) {
    await waitForLayout();
    const flowChanged = preferences.flow !== value.flow;
    preferences = value;
    const [background] = colors();
    document.body.style.background = background;
    document.getElementById('viewer').style.background = background;
    return preserve(async () => {
      if (flowChanged) {
        const cfi = anchor || (location && location.start.cfi);
        destroyRendition();
        createRendition();
        await rendition.display(cfi || undefined);
      }
      rendition.spread(value.columns === 1 ? 'none' : value.columns === 2 ? 'always' : 'auto', 800);
      rendition.settings.gap = value.margin * 2;
      for (const contents of rendition.getContents()) style(contents.document);
      if (auxiliary) style(auxiliary.contentDocument);
      await rendition.resize(window.innerWidth, window.innerHeight);
    });
  }
  async function next() {
    if (!rendition || auxiliary) return;
    await waitForLayout();
    if (location && location.atEnd) { send('end'); return; }
    restoring = true;
    try { await rendition.next(); await stable(rendition.getContents()); }
    finally { restoring = false; userMove = false; position(true); }
  }
  async function previous() {
    if (!rendition || auxiliary) return;
    await waitForLayout();
    restoring = true;
    try { await rendition.prev(); await stable(rendition.getContents()); }
    finally { restoring = false; userMove = false; position(true); }
  }
  async function display(target, changed = true) {
    if (auxiliary) closeAuxiliary();
    restoring = true;
    try { await displayStable(target); }
    finally { restoring = false; userMove = false; position(changed); }
  }
  async function displayStable(target) {
    await rendition.display(target);
    await stable(rendition.getContents());
  }
  async function turn(value) {
    if (!rendition || auxiliary) return;
    await waitForLayout();
    const move = value.delta > 0 ? next : previous;
    if (!value.snapshot || value.style === 'none' || (value.delta > 0 && location.atEnd)) return move();
    if (!/^data:image\/(jpeg|png);base64,/.test(value.snapshot)) return move();
    // Keep the native WebView visible: a Flutter raster overlay can suspend
    // its animation-frame callbacks before pagination has settled.
    const image = new Image(); image.src = value.snapshot;
    try { await timeout(image.decode(), 250); } catch (_) { return move(); }
    image.id = 'page-transition';
    Object.assign(image.style, {position:'fixed',inset:'0',width:'100%',height:'100%',zIndex:'1000',pointerEvents:'none',objectFit:'fill'});
    document.body.appendChild(image);
    const viewer = document.getElementById('viewer');
    try {
      await tick(); await move();
      const sign = (value.delta > 0) !== (config.direction === 'rtl') ? -1 : 1;
      const timing = {duration:190,easing:'cubic-bezier(.2,.7,.2,1)',fill:'forwards'};
      let old;
      if (value.style === 'curl') {
        image.style.transformOrigin = sign < 0 ? 'left center' : 'right center';
        old = image.animate([{transform:'perspective(1200px) rotateY(0deg)',filter:'brightness(1)'},
          {transform:`perspective(1200px) rotateY(${sign*100}deg)`,filter:'brightness(.7)'}],timing);
      } else old = image.animate([{transform:'translateX(0)'},{transform:`translateX(${sign*100}%)`}],timing);
      let incoming;
      if (value.style === 'slide') incoming = viewer.animate([{transform:`translateX(${-sign*100}%)`},{transform:'translateX(0)'}],timing);
      await old.finished;
      if (incoming) {await incoming.finished;incoming.cancel();}
    } finally {image.remove();}
  }
  async function legacyProgress(progression) {
    const all = rendition.getContents();
    const contents = all.find(content => location && content.sectionIndex === location.start.index) || all[0];
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
    if (disposed) return;
    createRendition();
    let restoredCfi = Boolean(value.cfi);
    try { await displayStable(value.cfi || value.href || undefined); }
    catch (error) {
      if (!value.cfi) throw error;
      restoredCfi = false;
      await displayStable(value.href || undefined);
    }
    await stable(rendition.getContents());
    if (!restoredCfi && value.progression > 0) await legacyProgress(value.progression);
    await tick(); restoring = false; userMove = false; anchor = restoredCfi ? value.cfi : (location && location.start.cfi);
    position(false); send('ready');
    window.addEventListener('resize', onResize);
    for (const event of inputEvents) document.addEventListener(event, noteUserMove, {passive: true});
  }
  function onResize() {
    if (disposed || !rendition) return;
    restoring = true;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { resizeTimer = null; preserve(() => rendition.resize(window.innerWidth, window.innerHeight)); }, 150);
  }
  function createRendition() {
    const before = new Set(book.spine.hooks.content.list());
    const current = rendition = book.renderTo('viewer', {width: window.innerWidth, height: window.innerHeight, resizeOnOrientationChange: false,
      manager: preferences.flow === 'scrolled' ? 'continuous' : 'default',
      flow: preferences.flow === 'scrolled' ? 'scrolled' : 'paginated',
      offset: Math.max(800, Math.min(1600, window.innerHeight * 2)),
      spread: preferences.columns === 1 ? 'none' : preferences.columns === 2 ? 'always' : 'auto',
      minSpreadWidth: 800, gap: preferences.margin * 2, direction: config.direction,
      allowScriptedContent: false, allowPopups: false});
    renditionSpineHooks = book.spine.hooks.content.list().filter(callback => !before.has(callback));
    rendition.hooks.content.register(hook);
    rendition.on('relocated', value => {
      if (rendition !== current || disposed) return;
      location = value;
      clearTimeout(relocationTimer);
      relocationTimer = setTimeout(() => {
        const changed = userMove || (preferences.flow === 'scrolled' && Date.now() < userMoveUntil);
        userMove = false; position(changed);
      }, 120);
    });
    rendition.on('displayError', error => { if (rendition === current && !restoring) send('error', {message: String(error)}); });
  }
  function destroyRendition() {
    const current = rendition;
    rendition = null;
    clearTimeout(relocationTimer);
    // Epub.js 0.3.93 leaves its bound identifier hook on the book at destroy.
    // Remove only hooks this rendition added; publication hooks stay intact.
    for (const callback of renditionSpineHooks) book.spine.hooks.content.deregister(callback);
    renditionSpineHooks = [];
    if (current) {
      const manager = current.manager;
      if (manager) {
        clearTimeout(manager.trimTimeout); clearTimeout(manager.scrollTimeout);
        if (manager._scrolled && manager._scrolled.cancel) manager._scrolled.cancel();
        if (manager.q) manager.q.stop();
      }
      if (current.q) current.q.stop();
      current.destroy();
      if (book.rendition === current) book.rendition = undefined;
    }
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
  window.reader = {open, next, previous, turn, display, preferences: setPreferences, search, openAuxiliary, closeAuxiliary,
    position: () => location, destroy: () => {
      disposed = true; clearTimeout(relocationTimer); clearTimeout(resizeTimer);
      window.removeEventListener('resize', onResize);
      for (const event of inputEvents) document.removeEventListener(event, noteUserMove);
      destroyRendition(); if (book) book.destroy();
    }};
})();
