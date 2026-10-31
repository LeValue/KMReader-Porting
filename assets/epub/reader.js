'use strict';
// Chromium captures the sheet directly in its compositor. Book pixels never
// cross the native bridge or get JPEG/base64 encoded for page navigation.
class KMReaderSheetEffect {
  static serial = 0;
  static supported() { return typeof document.startViewTransition === 'function'; }
  constructor(style, sign, preferences, y = .5) {
    this.style = style; this.sign = sign; this.preferences = preferences; this.y = y;
    this.width = innerWidth; this.height = innerHeight; this.progress = 0;
    this.id = `km-sheet-${++KMReaderSheetEffect.serial}`;
    this.sheet = document.createElement('style');
    this.sheet.dataset.pageMotion = this.id;
    this.sheet.textContent = `
      ::view-transition{pointer-events:none}
      :root{view-transition-name:none}#viewer{view-transition-name:km-reader-page}
      ::view-transition-group(km-reader-page){animation:none}
      ::view-transition-old(km-reader-page),::view-transition-new(km-reader-page){
        animation:km-sheet-hold 30s linear both paused;mix-blend-mode:normal;
        transform-origin:center;object-fit:fill;overflow:hidden}
      @keyframes km-sheet-hold{from{opacity:1}to{opacity:1}}`;
    document.head.appendChild(this.sheet);
    this.frames = document.createElement('style');
    this.frames.dataset.pageMotionFrame = this.id;
    document.head.appendChild(this.frames);
    const ns = 'http://www.w3.org/2000/svg';
    this.svg = document.createElementNS(ns, 'svg');
    this.svg.style.cssText = 'position:fixed;width:0;height:0;pointer-events:none';
    this.svg.innerHTML = `<defs><filter id="${this.id}" filterUnits="userSpaceOnUse" x="-${this.width}" y="-${this.height}" width="${this.width * 3}" height="${this.height * 3}" color-interpolation-filters="sRGB">
      <feImage x="0" y="0" width="${this.width}" height="${this.height}" preserveAspectRatio="none" result="map"/>
      <feDisplacementMap in="SourceGraphic" in2="map" scale="${this.width * 2}" xChannelSelector="R" yChannelSelector="G" result="warped"/>
      <feOffset in="warped" dx="${this.width / 255}" dy="${this.width / 255}" result="aligned"/>
      <feComposite in="aligned" in2="map" operator="in" result="clipped"/>
      <feComponentTransfer in="clipped" result="paper"><feFuncR type="linear"/><feFuncG type="linear"/><feFuncB type="linear"/></feComponentTransfer>
      <feColorMatrix in="map" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 1 0 0" result="shade"/>
      <feComposite in="shade" in2="clipped" operator="in" result="shadowed"/>
      <feMerge><feMergeNode in="paper"/><feMergeNode in="shadowed"/></feMerge>
      <feDropShadow dx="${sign * 6}" dy="2" stdDeviation="9" flood-opacity=".22"/>
    </filter><filter id="${this.id}-tint" color-interpolation-filters="sRGB"><feComponentTransfer><feFuncR type="linear"/><feFuncG type="linear"/><feFuncB type="linear"/></feComponentTransfer></filter></defs>`;
    document.body.appendChild(this.svg);
    this.canvas = document.createElement('canvas');
    this.canvas.width = 255; this.canvas.height = 64;
    this.context = this.canvas.getContext('2d');
  }
  async start(move) {
    let moved = false;
    try {
      this.transition = document.startViewTransition(async () => { moved = true; await move(); });
      // Both promises may reject independently when a viewport is hidden or
      // resized during capture. Always consume both, then expose the live page.
      this.transition.finished.then(() => this.stop(), () => this.stop());
      this.transition.updateCallbackDone.catch(() => {});
      await this.transition.ready;
      this.update(0);
      return true;
    } catch (_) {
      if (this.transition) await this.transition.updateCallbackDone.catch(() => {});
      if (!moved) await move();
      this.stop();
      return false;
    }
  }
  update(value) {
    if (this.stopped) return;
    const p = this.progress = Math.max(0, Math.min(1, value));
    const shape = Math.sin(Math.PI * p), radius = (Number(this.preferences.pageCornerRadius) || 0) * shape;
    const tint = Math.max(0, Math.min(.25, Number(this.preferences.pageTint) || 0)) * Math.min(1, shape * 2);
    for (const f of this.svg.querySelectorAll('feFuncR,feFuncG,feFuncB')) {
      f.setAttribute('slope', 1 - tint); f.setAttribute('intercept', tint);
    }
    const old = this.style === 'curl' ? 'none' : this.style === 'cover' ? 'none' : `translateX(${-this.sign * p * 100}%)`;
    const next = this.style === 'cover' ? `translateX(${this.sign * (1 - p) * 100}%)`
      : this.style === 'slide' ? `translateX(${this.sign * (1 - p) * 8}%)` : 'none';
    const filter = this.style === 'curl' ? `url(#${this.id})` : `url(#${this.id}-tint)`;
    if (this.style === 'curl') this.curlMap(p);
    const movingOld = this.style !== 'cover';
    this.frames.textContent = `
      ::view-transition-old(km-reader-page){transform:${old};z-index:${movingOld ? 2 : 1};filter:${movingOld ? filter : 'none'};border-radius:${movingOld ? radius : 0}px}
      ::view-transition-new(km-reader-page){transform:${next};z-index:${movingOld ? 1 : 2};filter:${movingOld ? 'none' : filter};border-radius:${movingOld ? 0 : radius}px}`;
  }
  curlMap(p) {
    const width = this.width, height = this.height, cw = this.canvas.width, ch = this.canvas.height;
    const data = this.context.createImageData(cw, ch), pixels = data.data;
    // A cylindrical sheet: flat front, a curved half-cylinder, then the
    // reflected back. The fold leans with the finger's vertical position.
    const radius = Math.max(.001, width * .10 * Math.sin(Math.PI * p));
    const base = width * (1 - p) - Math.PI * radius / 2;
    const lean = width * .16 * Math.sin(Math.PI * p) * (this.y - .5);
    for (let row = 0; row < ch; row++) {
      const fold = base + lean * (row / ch - .5);
      const edge = 2 * fold + Math.PI * radius - width;
      for (let col = 0; col < cw; col++) {
        const physicalX = (col + .5) * width / cw;
        const x = this.sign > 0 ? physicalX : width - physicalX;
        let source = x, alpha = 255, shade = 0;
        if (p >= .9999) alpha = 0;
        else if (p > .0001 && x >= fold && x <= fold + radius) {
          const angle = Math.asin(Math.max(0, Math.min(1, (x - fold) / radius)));
          source = fold + radius * (Math.PI - angle);
          shade = 36 + 60 * Math.sin(angle);
          if (source > width) alpha = 0;
        } else if (p > .0001 && x >= Math.max(0, edge) && x < fold) {
          source = 2 * fold + Math.PI * radius - x; shade = 18;
          if (source > width) alpha = 0;
        } else if (x > fold + radius && p > .0001) alpha = 0;
        if (this.sign < 0) source = width - source;
        const index = (row * cw + col) * 4;
        pixels[index] = Math.max(0, Math.min(255, Math.round(128 + (source - physicalX) * 255 / (2 * width))));
        pixels[index + 1] = 128; pixels[index + 2] = shade; pixels[index + 3] = alpha;
      }
    }
    this.context.putImageData(data, 0, 0);
    this.svg.querySelector('feImage').setAttribute('href', this.canvas.toDataURL('image/png'));
  }
  animateTo(target, duration) {
    if (this.stopped) return Promise.resolve();
    if (this.finishAnimation) this.finishAnimation();
    cancelAnimationFrame(this.frame);
    return new Promise(resolve => {
      this.finishAnimation = resolve;
      const from = this.progress, start = performance.now();
      const frame = now => {
        if (this.stopped) { resolve(); return; }
        const t = Math.min(1, (now - start) / Math.max(1, duration));
        this.update(from + (target - from) * (1 - Math.pow(1 - t, 3)));
        if (t < 1) this.frame = requestAnimationFrame(frame);
        else { this.finishAnimation = null; resolve(); }
      };
      this.frame = requestAnimationFrame(frame);
    });
  }
  stop() {
    if (this.stopped) return;
    this.stopped = true;
    cancelAnimationFrame(this.frame);
    this.finishAnimation?.(); this.finishAnimation = null;
    this.transition?.skipTransition(); this.sheet.remove(); this.frames.remove(); this.svg.remove();
  }
}

(() => {
  let book, rendition, config, preferences, location, auxiliary, anchor;
  let renditionSpineHooks = [], operationQueue = Promise.resolve(), turnAnimation, sheetEffect, gesture;
  let interactiveNavigation = false, suppressClickUntil = 0;
  const settledDocuments = new WeakSet();
  function enqueue(operation) {
    const pending = operationQueue.then(() => disposed ? undefined : operation());
    operationQueue = pending.catch(() => {});
    return pending;
  }
  let userMoveUntil = 0;
  let restoring = true, disposed = false, userMove = false, relocationTimer, resizeTimer = null, layoutJobs = 0;
  const tick = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const inputEvents = ['wheel', 'touchstart', 'touchmove'];
  const noteUserMove = () => {
    if (!restoring && !disposed) {
      if (!gesture) cancelTurnAnimation();
      userMove = true; userMoveUntil = Date.now() + 2000;
      // A no-op programmatic scroll can leave Epub.js ignoring its next event.
      // Real input owns that next scroll and must update the reading locator.
      if (rendition?.manager) rendition.manager.ignore = false;
    }
  };
  const send = (type, value = {}) => {
    if (disposed || !config) return;
    const message = {type, ...value, nonce: config.nonce};
    if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('readerEvent', message);
    else window.dispatchEvent(new CustomEvent('readerEvent', {detail: message}));
  };
  const timeout = (promise, ms = 6000) => {
    let timer;
    return Promise.race([promise, new Promise(resolve => {timer = setTimeout(resolve, ms);})])
      .finally(() => clearTimeout(timer));
  };
  const colors = () => /^#[a-f0-9]{6}$/i.test(preferences.backgroundColor || '') && /^#[a-f0-9]{6}$/i.test(preferences.textColor || '') ? [preferences.backgroundColor, preferences.textColor] : preferences.theme === 'black' ? ['#1c1c1e', '#e8e4dc'] : preferences.theme === 'white' ? ['#ffffff', '#262321'] : ['#efe5d0', '#262321'];
  const isFixedLayout = () => Boolean(book && (book.package?.metadata.layout === 'pre-paginated' || book.displayOptions?.fixedLayout === 'true'));
  const verticalWriting = () => Boolean(rendition?.manager?.writingMode?.startsWith('vertical'));
  const spreadPreference = value => verticalWriting() ? 'none' : value.columns === 1 ? 'none' : value.columns === 2 ? 'always'
    : isFixedLayout() && book.package?.metadata.spread === 'none' ? 'none'
    : isFixedLayout() && book.package?.metadata.spread === 'both' ? 'always' : 'auto';
  function atReadingEnd() {
    if (!location?.atEnd) return false;
    if (preferences.flow !== 'scrolled' || !rendition?.manager?.container) return true;
    const manager = rendition.manager, container = manager.container;
    return manager.settings.axis === 'horizontal'
      ? container.scrollWidth - container.clientWidth - Math.abs(container.scrollLeft) <= 2
      : container.scrollHeight - container.clientHeight - container.scrollTop <= 2;
  }
  // Axis selection happens before rendition content hooks. Adapt the public
  // Contents getter so body-declared CJK writing modes are visible in time.
  const nativeWritingMode = ePub.Contents.prototype.writingMode;
  ePub.Contents.prototype.writingMode = function(value) {
    if (!value && !isFixedLayout() && this.document.body) {
      const root = nativeWritingMode.call(this);
      const body = this.window.getComputedStyle(this.document.body).writingMode;
      if (body.startsWith('vertical') && !root.startsWith('vertical')) nativeWritingMode.call(this, body);
    }
    return nativeWritingMode.call(this, value);
  };
  function style(document) {
    document.documentElement.style.touchAction = preferences.flow === 'paged' ? 'pan-y pinch-zoom' : 'auto';
    const [background, foreground] = colors();
    let head = document.head || document.querySelector('head');
    if (!head) { head = document.createElementNS('http://www.w3.org/1999/xhtml', 'head'); document.documentElement.prepend(head); }
    let sheet = document.getElementById('kmreader-preferences');
    if (!sheet) { sheet = document.createElementNS('http://www.w3.org/1999/xhtml', 'style'); sheet.id = 'kmreader-preferences'; head.appendChild(sheet); }
    // Fixed pages position artwork and text in an authored coordinate system.
    // Reflow typography or color overrides would change that composition.
    if (isFixedLayout()) { sheet.textContent = ''; return; }
    const custom = preferences.fontUrl && new URL(preferences.fontUrl).origin === window.location.origin;
    const family = custom ? 'font-family:kmreader-custom !important;' : ['serif','sans-serif'].includes(preferences.font) ? `font-family:${preferences.font} !important;` : '';
    const face = custom ? `@font-face{font-family:kmreader-custom;src:url("${preferences.fontUrl}");font-display:block;}` : '';
    const align = preferences.advancedLayout !== false && ['left', 'right', 'justify', 'center'].includes(preferences.alignment) ? `text-align:${preferences.alignment} !important;` : '';
    sheet.textContent = `${face}html,body{background:${background} !important;color:${foreground} !important;}
      body{${preferences.advancedLayout === false ? '' : `font-size:${preferences.fontSize}px !important;line-height:${preferences.lineHeight} !important;`}${family}${align}${preferences.fontWeight > 0 ? `font-weight:${preferences.fontWeight} !important;` : ''}}
      ${preferences.advancedLayout === false ? '' : `p{margin-block-end:${preferences.paragraphSpacing}em !important;text-indent:${preferences.indent}em !important;} body{letter-spacing:${preferences.letterSpacing}em !important;word-spacing:${preferences.wordSpacing}em !important;}`}
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
    for (const content of contents) settledDocuments.add(content.document || content);
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
  function visibleTextCfi(contents, viewport) {
    const nodes = textIndex(contents).nodes, doc = contents.document;
    let mapped;
    try { mapped = contents.range(location.start.cfi); } catch (_) { return; }
    let first = nodes.indexOf(mapped.startContainer);
    if (first < 0) first = nodes.findIndex(node => mapped.startContainer.contains(node));
    if (first < 0) first = 0;
    const range = doc.createRange();
    const visible = () => [...range.getClientRects()].some(rect =>
      rect.width > 0 && rect.height > 0 && rect.right > viewport.left + 1 &&
      rect.left < viewport.right - 1 && rect.bottom > viewport.top + 1 &&
      rect.top < viewport.bottom - 1);
    // The mapper identifies the paragraph. Prefix visibility is monotonic, so
    // binary search finds its first visible UTF-16 offset without scanning the
    // chapter character by character or relying on platform caret hit testing.
    for (let i = first; i < Math.min(nodes.length, first + 64); i++) {
      const node = nodes[i];
      if (!node.length || !node.textContent.trim()) continue;
      range.selectNodeContents(node);
      if (!visible()) continue;
      let low = 0, high = node.length - 1;
      while (low < high) {
        const middle = Math.floor((low + high) / 2);
        range.setStart(node, 0); range.setEnd(node, middle + 1);
        if (visible()) high = middle; else low = middle + 1;
      }
      range.setStart(node, low); range.collapse(true);
      return contents.cfiFromRange(range);
    }
  }
  function refineVerticalLocator() {
    if (!verticalWriting() || isFixedLayout() || !location) return;
    const contents = rendition.getContents().find(content => content.sectionIndex === location.start.index);
    const doc = contents?.document, frame = doc?.defaultView?.frameElement;
    if (!frame) return;
    const viewport = rendition.manager.container.getBoundingClientRect(), bounds = frame.getBoundingClientRect();
    const style = doc.defaultView.getComputedStyle(doc.body);
    const leftToRight = contents.writingMode().endsWith('-lr');
    const edge = leftToRight ? viewport.left - bounds.left : viewport.right - bounds.left;
    const padding = parseFloat(leftToRight ? style.paddingLeft : style.paddingRight) || 0;
    const top = viewport.top - bounds.top, right = viewport.right - bounds.left, left = viewport.left - bounds.left;
    // The stock mapper can return the same paragraph start for successive
    // pages of large vertical text. Ask the browser for the visible character.
    const fontSize = parseFloat(style.fontSize) || 16, lineHeight = parseFloat(style.lineHeight) || fontSize * 1.5;
    for (const inset of [padding + lineHeight / 2, padding + fontSize / 2, padding + 1]) {
      for (const dy of [fontSize / 2, fontSize, lineHeight / 2]) {
        const x = edge + (leftToRight ? inset : -inset);
        const y = top + (parseFloat(style.paddingTop) || 0) + dy;
        const range = doc.caretRangeFromPoint?.(x, y);
        if (!range || range.startContainer.nodeType !== Node.TEXT_NODE || !range.startContainer.textContent.trim()) continue;
        const rect = range.getBoundingClientRect();
        if ((rect.width || rect.height) && rect.right >= left && rect.left <= right && rect.top >= top - 1 && rect.top < top + viewport.height) {
          const cfi = contents.cfiFromRange(range);
          if (cfi === anchor) continue;
          location.start.cfi = cfi;
          return;
        }
      }
    }
    const cfi = visibleTextCfi(contents, {left, right, top, bottom: top + viewport.height});
    if (cfi) location.start.cfi = cfi;
  }
  function position(changed = false) {
    if (!location || restoring || auxiliary || interactiveNavigation) return;
    // Delayed Epub.js reports contain a coarse paragraph CFI, which can lie on
    // the preceding page in large vertical text. Only real navigation chooses
    // a new anchor; reflow/reporting must retain the committed character CFI.
    if (changed || !anchor) refineVerticalLocator();
    else location.start.cfi = anchor;
    const start = location.start, displayed = start.displayed || {page: 1, total: 1};
    changed = changed && start.cfi !== anchor;
    if (changed) {
      anchor = start.cfi;
      if (preferences.flow === 'scrolled') userMoveUntil = Date.now() + 2000;
    }
    send('position', {cfi: start.cfi, href: start.href, page: displayed.page, pages: displayed.total,
      progression: progression(start, displayed),
      totalProgression: Number.isFinite(start.percentage) ? start.percentage : null,
      atStart: !!location.atStart, atEnd: atReadingEnd(), changed});
  }
  function hook(contents) {
    const section = book.spine.get(contents.sectionIndex);
    const doc = contents.document;
    const active = () => doc.defaultView && doc.defaultView.frameElement && doc.defaultView.frameElement.isConnected;
    if (!doc.documentElement.lang && config.language) doc.documentElement.lang = config.language;
    if (!doc.documentElement.dir && config.direction === 'rtl' && !contents.writingMode().startsWith('vertical')) doc.documentElement.dir = 'rtl';
    style(doc);
    if (preferences.flow === 'scrolled' && rendition.manager?.stage) {
      // The first CJK view can change the manager axis after its stage chose
      // overflow-x/y. Reapply that policy so the new axis accepts input.
      const manager = rendition.manager;
      manager.stage.overflow(manager.overflow || 'scroll');
    }
    doc.addEventListener('click', event => {
      if (Date.now() < suppressClickUntil) { event.preventDefault(); event.stopImmediatePropagation(); return; }
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
      if (event.key === 'F11') { event.preventDefault(); send('fullscreen'); }
      else if (event.key === ' ' && preferences.spaceKeyAction === 'toggleControls') { event.preventDefault(); send('controls'); }
      else if ([rtl ? 'ArrowLeft' : 'ArrowRight', 'PageDown', ' '].includes(event.key)) {
        event.preventDefault(); send('turn', {delta: 1});
      } else if ([rtl ? 'ArrowRight' : 'ArrowLeft', 'PageUp'].includes(event.key)) {
        event.preventDefault(); send('turn', {delta: -1});
      } else if (event.key === 'Escape') send('close');
    });
    let contact;
    const point = event => {
      const frame = doc.defaultView.frameElement.getBoundingClientRect();
      return {x: frame.left + event.clientX, y: frame.top + event.clientY};
    };
    doc.addEventListener('pointerdown', event => {
      if (!event.isPrimary || (event.pointerType === 'mouse' && event.button !== 0)) {
        cancelGesture(); contact = null; return;
      }
      const p = point(event);
      const edge = p.x < innerWidth * .18 || p.x > innerWidth * .82;
      contact = event.target.closest?.('a[href]') || (event.pointerType === 'mouse' && !edge)
        ? null : {id:event.pointerId,x:p.x,y:p.y,time:Date.now()};
      if (contact && event.pointerType === 'mouse' && edge && preferences.flow === 'paged') {
        event.preventDefault();
        try { doc.documentElement.setPointerCapture(event.pointerId); } catch (_) {}
      }
    }, {passive:false});
    doc.addEventListener('dragstart', event => { if (preferences.flow === 'paged') event.preventDefault(); });
    doc.addEventListener('pointermove', event => {
      if (gesture?.pointer === event.pointerId) { event.preventDefault(); gesture.update(point(event)); return; }
      if (!contact || event.pointerId !== contact.id || preferences.flow !== 'paged' || auxiliary ||
          !doc.getSelection().isCollapsed) return;
      const p = point(event), dx = p.x - contact.x, dy = p.y - contact.y;
      if (Math.abs(dx) < 14 || Math.abs(dx) < Math.abs(dy) * 1.3 || Date.now() - contact.time > 550) return;
      if (preferences.followGesture !== false && motionAllowed(preferences.transition) && KMReaderSheetEffect.supported()) {
        event.preventDefault();
        beginGesture(contact, p, event.pointerId);
        contact = null;
      }
    }, {passive:false});
    doc.addEventListener('pointerup', event => {
      if (gesture?.pointer === event.pointerId) { event.preventDefault(); gesture.update(point(event)); gesture.release(); contact = null; return; }
      if (!contact || event.pointerId !== contact.id) return;
      const p = point(event), dx = p.x - contact.x, dy = p.y - contact.y;
      if (preferences.flow === 'paged' && doc.getSelection().isCollapsed && Math.abs(dx) > 45 &&
          Math.abs(dx) > Math.abs(dy) * 1.3 && Date.now() - contact.time < 1000) {
        event.preventDefault(); suppressClickUntil = Date.now() + 500;
        send('turn', {delta: dx < 0 !== (config.direction === 'rtl') ? 1 : -1});
      }
      contact = null;
    }, {passive:false});
    doc.addEventListener('pointercancel', () => { contact = null; cancelGesture(); });
    doc.addEventListener('wheel', noteUserMove, {passive: true});
    let reflowQueued = false;
    const resourceChanged = () => {
      settledDocuments.delete(doc);
      if (!active() || restoring || !location || reflowQueued) return;
      reflowQueued = true;
      enqueue(async () => {
        reflowQueued = false;
        if (active()) await preserve(() => Promise.resolve());
      }).catch(error => send('error', {message: String(error)}));
    };
    for (const image of doc.images) image.addEventListener('load', resourceChanged);
    if (doc.fonts) doc.fonts.addEventListener('loadingdone', resourceChanged);
    doc.addEventListener('selectionchange', () => {
      const selection = doc.getSelection();
      if (!selection.isCollapsed && selection.toString().trim()) send('selection', {text: selection.toString().slice(0, 16000)});
    });
  }
  function resizePublication(width, height) {
    const manager = rendition.manager;
    if (isFixedLayout() || preferences.flow !== 'paged' || !manager?.views?.length) {
      rendition.resize(width, height); return;
    }
    // DefaultManager.resize clears every iframe and asks Rendition to display
    // again. Keep the live reflowable document while updating its column box.
    rendition.settings.width = width; rendition.settings.height = height;
    manager.stage.size(width, height);
    manager._stageSize = manager.stage.size(); manager._bounds = manager.bounds();
    manager.updateLayout();
    manager.views.forEach(view => {
      view.size(manager.layout.width, manager.layout.height);
      view.setLayout(manager.layout);
    });
  }
  function layoutReady() {
    return !restoring && resizeTimer === null && layoutJobs === 0 &&
      Boolean(rendition?.getContents().length);
  }
  async function waitForLayout() {
    if (resizeTimer !== null) {
      clearTimeout(resizeTimer); resizeTimer = null;
      await preserve(() => resizePublication(window.innerWidth, window.innerHeight));
    }
    const deadline = Date.now() + 10000;
    while (restoring || resizeTimer !== null || layoutJobs > 0) {
      if (disposed) return;
      if (Date.now() > deadline) throw new Error('The EPUB layout did not settle.');
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
  async function preserve(change) {
    if (!rendition) return;
    cancelTurnAnimation();
    const cfi = anchor || (location && location.start.cfi);
    if (layoutJobs === 0) send('layout', {active:true});
    layoutJobs++; restoring = true; userMove = false; userMoveUntil = 0; clearTimeout(relocationTimer);
    try {
      await change();
      await stable(rendition.getContents());
      if (cfi) await displayStable(cfi);
      await tick();
    } finally { layoutJobs--; restoring = layoutJobs > 0; position(false); if (!restoring) send('layout', {active:false}); }
  }
  function setPreferences(value) {
    cancelGesture();
    // Flow changes replace the manager. Keep rapid preference updates ordered
    // so an older reflow cannot destroy a newer rendition or restore its CFI.
    return enqueue(() => applyPreferences(value));
  }
  async function applyPreferences(value) {
    await waitForLayout();
    const motionKeys = new Set(['animationDuration','followGesture','pageTint','pageCornerRadius','animate','transition']);
    if ([...new Set([...Object.keys(preferences), ...Object.keys(value)])].every(key =>
        motionKeys.has(key) || JSON.stringify(preferences[key]) === JSON.stringify(value[key]))) {
      cancelTurnAnimation(); preferences = value; return;
    }
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
      rendition.spread(spreadPreference(value), 800);
      rendition.settings.gap = isFixedLayout() ? 0 : value.margin * 2;
      for (const contents of rendition.getContents()) style(contents.document);
      if (auxiliary) style(auxiliary.contentDocument);
      resizePublication(window.innerWidth, window.innerHeight);
    });
  }
  function refreshViewportLocation() {
    // Reading the current location also synchronizes Epub.js layout with the
    // actual native viewport. A turn must not use cached geometry from before
    // the reader was shown or a settings sheet finished closing.
    const current = rendition.currentLocation();
    if (current?.start) location = current;
  }
  async function advance(delta) {
    refreshViewportLocation();
    const manager = rendition.manager;
    if (!isFixedLayout() && !manager.isPaginated && manager.settings.axis === 'horizontal') {
      const fraction = preferences.flow === 'scrolled' ? (Number(preferences.tapScroll) || 80) / 100 : 1;
      manager.scrollBy(delta * manager.container.clientWidth * fraction, 0, true);
      await manager.q.enqueue(() => manager.check());
      rendition.reportLocation();
    } else if (!isFixedLayout() && preferences.flow === 'scrolled' && !manager.isPaginated && manager.container) {
      manager.scrollBy(0, delta * manager.container.clientHeight * (Number(preferences.tapScroll) || 80) / 100, true);
      await manager.q.enqueue(() => manager.check());
      rendition.reportLocation();
    } else if (delta > 0) await rendition.next();
    else await rendition.prev();
    // The manager already completes the move on its rendering queue. Existing
    // chapter documents have settled fonts/images; four extra RAFs on every
    // page only delay input. New chapters still wait for complete layout.
    const contents = rendition.getContents();
    if (contents.some(content => !settledDocuments.has(content.document))) {
      await stable(contents);
    }
    // Epub.js resolves reportLocation's queue job before its RAF callback emits
    // relocated. Read the settled viewport before committing this user turn;
    // otherwise the old locator can be treated as an unchanged position.
    refreshViewportLocation();
  }
  async function next() {
    if (!rendition || auxiliary) return;
    await waitForLayout();
    if (atReadingEnd()) { send('end'); return; }
    restoring = true;
    try { await advance(1); }
    finally { restoring = false; userMove = false; position(true); }
  }
  async function previous() {
    if (!rendition || auxiliary) return;
    await waitForLayout();
    restoring = true;
    try { await advance(-1); }
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
    // Continuous moveTo only applies target.top. Vertical pagination also
    // reuses a width-based delta after reflow. Align locators on the real axis.
    const manager = rendition.manager;
    const horizontalFlow = !manager?.isPaginated && manager?.settings.axis === 'horizontal';
    const verticalPages = manager?.isPaginated && manager?.settings.axis === 'vertical' && !isFixedLayout();
    if ((!horizontalFlow && !verticalPages) || typeof target !== 'string') return;
    let range;
    if (target.startsWith('epubcfi(')) {
      const cfi = new ePub.CFI(target);
      const contents = rendition.getContents().find(content => content.sectionIndex === cfi.spinePos);
      if (contents) range = contents.range(target);
    }
    else if (target.includes('#')) {
      let id;
      try { id = decodeURIComponent(target.slice(target.indexOf('#') + 1)); } catch (_) { return; }
      const section = book.spine.get(target);
      const contents = rendition.getContents().find(content => (!section || content.sectionIndex === section.index) && content.document.getElementById(id));
      const element = contents?.document.getElementById(id);
      if (element) { range = contents.document.createRange(); range.selectNodeContents(element); }
    }
    if (!range) return;
    const frame = range.startContainer.ownerDocument.defaultView.frameElement;
    const bounds = frame.getBoundingClientRect(), rect = range.getBoundingClientRect();
    const viewport = manager.container.getBoundingClientRect();
    if (verticalPages) {
      const height = manager.layout.height;
      const top = Math.max(0, Math.floor((manager.container.scrollTop + bounds.top + rect.top - viewport.top) / height) * height);
      if (Math.abs(top - manager.container.scrollTop) > 1) manager.scrollTo(manager.container.scrollLeft, top, true);
    } else {
      const delta = config.direction === 'rtl'
        ? bounds.left + rect.right - viewport.right
        : bounds.left + rect.left - viewport.left;
      if (Math.abs(delta) > 1) manager.scrollTo(manager.container.scrollLeft + delta, manager.container.scrollTop, true);
    }
    rendition.reportLocation();
    await tick();
  }
  function cancelTurnAnimation() {
    sheetEffect?.stop(); sheetEffect = undefined;
    const previous = turnAnimation; turnAnimation = undefined;
    if (previous) previous.cancel();
  }
  function cancelGesture() { if (gesture) { gesture.invalidated = true; gesture.finish(false); } }
  function beginGesture(contact, point, pointer) {
    if (gesture || disposed) return;
    const physical = point.x < contact.x ? 1 : -1;
    const delta = (physical > 0) !== (config.direction === 'rtl') ? 1 : -1;
    if (delta > 0 && atReadingEnd() || delta < 0 && location?.atStart) return;
    cancelTurnAnimation();
    const shield = document.createElement('div');
    shield.id = 'page-gesture';
    shield.style.cssText = 'position:fixed;inset:0;z-index:2147483646;touch-action:none;cursor:grabbing';
    document.body.appendChild(shield);
    let resolve;
    const finished = new Promise(done => resolve = done);
    const state = gesture = {progress:0,effect:null,ended:false,invalidated:false,width:innerWidth,height:innerHeight,
      finish: commit => { if (!state.ended) { state.ended = true; resolve(commit && innerWidth === state.width && innerHeight === state.height); } }};
    let lastX = point.x, lastTime = performance.now(), velocity = 0;
    const update = p => {
      const now = performance.now(), elapsed = Math.max(1, now - lastTime);
      if (Math.abs(p.x - lastX) > .1) velocity = -(p.x - lastX) * physical / elapsed;
      else if (elapsed > 90) velocity = 0;
      lastX = p.x; lastTime = now;
      state.progress = Math.max(0, Math.min(1, (contact.x - p.x) * physical / innerWidth));
      state.effect?.update(state.progress);
    };
    state.update = update;
    state.pointer = pointer;
    state.release = () => state.finish(state.progress > .28 || state.progress > .06 && velocity > .45);
    update(point);
    shield.addEventListener('pointermove', event => {
      if (!event.isPrimary || event.pointerId !== pointer) { state.finish(false); return; }
      event.preventDefault(); update({x:event.clientX,y:event.clientY});
    }, {passive:false});
    shield.addEventListener('pointerup', event => {
      if (event.pointerId !== pointer) return;
      event.preventDefault(); update({x:event.clientX,y:event.clientY});
      state.finish(state.progress > .28 || state.progress > .06 && velocity > .45);
    });
    shield.addEventListener('pointercancel', () => state.finish(false));

    shield.addEventListener('pointerdown', event => { if (event.pointerId !== pointer) state.finish(false); });
    // Keep input in its original document. Moving capture between a book iframe
    // and the top document can deadlock Chromium's input router during capture.
    const safety = setTimeout(() => state.finish(false), 10000);
    enqueue(async () => {
      const saved = anchor || location?.start?.cfi;
      interactiveNavigation = true;
      try {
        state.effect = await transitionMove(delta, preferences.transition, contact.y / innerHeight);
        state.effect?.update(state.progress);
        let commit = await finished;
        const duration = Math.min(300, Math.max(80, (Number(preferences.animationDuration) || 380) *
          (commit ? 1 - state.progress : state.progress)));
        if (!disposed) await state.effect?.animateTo(commit ? 1 : 0, duration);
        state.effect?.stop();
        commit = commit && !state.invalidated;
        if (!disposed && !commit && saved) {
          await displayStable(saved); refreshViewportLocation(); anchor = saved;
        }
        interactiveNavigation = false;
        if (!disposed) { refreshViewportLocation(); userMove = false; position(commit); }
      } finally {
        state.effect?.stop();
        if (sheetEffect === state.effect) sheetEffect = undefined;
        interactiveNavigation = false;
        clearTimeout(safety); shield.remove();
        if (gesture === state) gesture = undefined;
        suppressClickUntil = Date.now() + 500;
      }
    }).catch(error => send('error', {message:String(error)}));
  }
  function motionAllowed(style) {
    return preferences.animate !== false && preferences.flow === 'paged' && style !== 'none' &&
      !matchMedia('(prefers-reduced-motion: reduce)').matches;
  }
  async function capturedLayout(move) {
    // View Transitions freeze painting until their update resolves. Epub.js
    // queues layout on RAF, so use task turns during this brief frozen update;
    // geometry is still synchronously available. Restore schedulers afterward.
    const raf = window.requestAnimationFrame;
    const schedule = callback => setTimeout(() => callback(performance.now()), 0);
    const queues = [rendition.q, rendition.manager?.q].filter(Boolean).map(q => [q, q.tick]);
    window.requestAnimationFrame = schedule;
    for (const [q] of queues) q.tick = schedule;
    try { return await move(); }
    finally {
      window.requestAnimationFrame = raf;
      for (const [q, tick] of queues) q.tick = tick;
    }
  }
  async function transitionMove(delta, style, y) {
    const move = () => delta > 0 ? next() : previous();
    if (!motionAllowed(style) || !KMReaderSheetEffect.supported() || (delta > 0 && atReadingEnd())) {
      await move(); return null;
    }
    await tick();
    const effect = sheetEffect = new KMReaderSheetEffect(style,
      (delta > 0) !== (config.direction === 'rtl') ? 1 : -1, preferences, y);
    if (!await effect.start(() => capturedLayout(move))) { if (sheetEffect === effect) sheetEffect = undefined; return null; }
    return effect;
  }
  async function turn(value) {
    if (!rendition || auxiliary) return;
    cancelTurnAnimation();
    const effect = await transitionMove(value.delta, value.style || preferences.transition, .5);
    if (!effect || disposed) return;
    // Navigation is already committed. Cosmetic motion never owns the input
    // queue, and the next input can replace this compositor transition.
    const duration = Math.max(150, Math.min(900, Number(preferences.animationDuration) || 380));
    effect.animateTo(1, duration).then(() => {
      effect.stop(); if (sheetEffect === effect) sheetEffect = undefined;
    });
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
    await tick();
    // Ready must describe a real viewport, even if the initial relocated
    // callback is still queued by the renderer.
    refreshViewportLocation();
    restoring = false; userMove = false; anchor = restoredCfi ? value.cfi : (location && location.start.cfi);
    position(false); send('ready', {layout: isFixedLayout() ? 'pre-paginated' : 'reflowable', writingMode: rendition.manager?.writingMode || 'horizontal-tb'});
    window.addEventListener('resize', onResize);
    for (const event of inputEvents) document.addEventListener(event, noteUserMove, {passive: true});
  }
  function onResize() {
    cancelGesture();
    if (disposed || !rendition) return;
    cancelTurnAnimation();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      resizeTimer = null;
      enqueue(() => preserve(() => resizePublication(window.innerWidth, window.innerHeight)))
        .catch(error => send('error', {message: String(error)}));
    }, 80);
  }
  function createRendition() {
    const before = new Set(book.spine.hooks.content.list());
    const current = rendition = book.renderTo('viewer', {width: window.innerWidth, height: window.innerHeight, resizeOnOrientationChange: false,
      manager: preferences.flow === 'scrolled' ? 'continuous' : 'default',
      flow: preferences.flow === 'scrolled' ? 'scrolled' : 'paginated',
      offset: Math.max(800, Math.min(1600, window.innerHeight * 2)),
      spread: spreadPreference(preferences),
      minSpreadWidth: 800, gap: isFixedLayout() ? 0 : preferences.margin * 2, direction: config.direction,
      allowScriptedContent: false, allowPopups: false});
    renditionSpineHooks = book.spine.hooks.content.list().filter(callback => !before.has(callback));
    rendition.hooks.content.register(hook);
    rendition.on('relocated', value => {
      if (rendition !== current || disposed) return;
      location = value;
      if (!restoring && !interactiveNavigation && anchor && !userMove &&
          !(preferences.flow === 'scrolled' && Date.now() < userMoveUntil)) {
        location.start.cfi = anchor;
      }
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
  window.reader = {open: value => enqueue(() => open(value)), next: () => enqueue(next), previous: () => enqueue(previous),
    turn: value => enqueue(() => turn(value)), display: (target, changed) => enqueue(() => display(target, changed)),
    preferences: setPreferences, search: value => enqueue(() => search(value)),
    openAuxiliary: value => enqueue(() => openAuxiliary(value)), closeAuxiliary: () => enqueue(closeAuxiliary),
    position: () => location, layoutReady,
    whenIdle: () => enqueue(waitForLayout), destroy: () => {
      disposed = true; cancelGesture(); clearTimeout(relocationTimer); clearTimeout(resizeTimer);
      cancelTurnAnimation();
      window.removeEventListener('resize', onResize);
      for (const event of inputEvents) document.removeEventListener(event, noteUserMove);
      destroyRendition(); if (book) book.destroy();
    }};
})();
