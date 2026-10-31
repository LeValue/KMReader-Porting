'use strict';
// Slide uses compositor snapshots; curl samples full-resolution page textures
// with an analytic cylinder in WebGL. No per-frame bitmap encoding/readback.
class KMReaderCurlSurface {
  static shared;
  constructor() {
    this.canvas = document.createElement('canvas');
    this.canvas.id = 'page-curl-surface';
    this.canvas.style.cssText = 'position:fixed;inset:0;width:100%;height:100%;pointer-events:none;z-index:2147483645';
    const gl=this.gl=this.canvas.getContext('webgl',{alpha:false,antialias:false,preserveDrawingBuffer:false});
    if (!gl) throw Error('WebGL unavailable');
    const compile=(kind,source)=>{const shader=gl.createShader(kind);gl.shaderSource(shader,source);gl.compileShader(shader);if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(shader));return shader;};
    const vertex=compile(gl.VERTEX_SHADER,'attribute vec2 a;varying vec2 v;void main(){v=vec2((a.x+1.)*.5,(1.-a.y)*.5);gl_Position=vec4(a,0.,1.);}');
    const fragment=compile(gl.FRAGMENT_SHADER,`precision highp float;
      varying vec2 v;uniform sampler2D oldPage,newPage;
      uniform vec2 size;uniform float progress,spread,sign,slope,grabY;uniform vec3 paper;
      vec4 oldAt(vec2 q){return texture2D(oldPage,clamp(q/size,vec2(0.),vec2(1.)));}
      vec4 newAt(vec2 q){return texture2D(newPage,clamp(q/size,vec2(0.),vec2(1.)));}
      void main(){
        vec2 screen=v*size;float w=size.x/(1.+spread),hinge=spread>.5?size.x*.5:(sign>0.?0.:size.x);
        vec2 q=vec2((screen.x-hinge)*sign,screen.y),n=normalize(vec2(1.,slope));
        float p=progress,r=max(.001,w*.105*sin(3.14159265*p));
        vec2 origin=vec2(w*(1.-p)-1.5707963*r,grabY*size.y);
        float d=dot(q-origin,n),edge;
        vec4 under=spread>.5&&q.x<0.?oldAt(screen):newAt(screen);
        if(p<.0001){gl_FragColor=oldAt(screen);return;}
        if(p>.9999){gl_FragColor=newAt(screen);return;}
        vec2 source=q;bool back=false;float shade=1.;bool sheet=false;
        if(d>=0.&&d<=r){
          float angle=asin(clamp(d/r,0.,1.));source=q+n*(r*(3.14159265-angle)-d);
          back=true;shade=.88+.12*cos(angle);sheet=true;
        }else if(d<0.){
          vec2 reflected=q+n*(3.14159265*r-2.*d);
          if(reflected.x>=0.&&reflected.x<=w&&reflected.y>=0.&&reflected.y<=size.y){source=reflected;back=true;sheet=true;}
          else if(q.x>=0.&&q.x<=w){source=q;sheet=true;}
        }
        if(source.x<0.||source.x>w||source.y<0.||source.y>size.y)sheet=false;
        if(sheet){
          vec2 tex=vec2(hinge+source.x*sign,source.y);
          vec4 color=oldAt(tex);
          if(back){
            if(spread>.5)color=newAt(vec2(hinge-source.x*sign,source.y));
            else {vec3 stock=oldAt(vec2(sign>0.?1.:size.x-1.,1.)).rgb;color=vec4(mix(stock,color.rgb,.36),1.);}
          }
          gl_FragColor=vec4(color.rgb*shade,1.);
        }else{
          float shadow=exp(-abs(d-r)/max(2.,w*.025))*.10*sin(3.14159265*p);
          gl_FragColor=vec4(under.rgb*(1.-shadow),1.);
        }
      }`);
    const program=this.program=gl.createProgram();gl.attachShader(program,vertex);gl.attachShader(program,fragment);gl.linkProgram(program);gl.deleteShader(vertex);gl.deleteShader(fragment);
    if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(program));
    gl.useProgram(program);const buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,1,1]),gl.STATIC_DRAW);
    const a=gl.getAttribLocation(program,'a');gl.enableVertexAttribArray(a);gl.vertexAttribPointer(a,2,gl.FLOAT,false,0,0);
    this.uniforms={};for(const name of ['oldPage','newPage','size','progress','spread','sign','slope','grabY','paper'])this.uniforms[name]=gl.getUniformLocation(program,name);
    this.textures=[0,1].map(i=>{gl.activeTexture(gl.TEXTURE0+i);const t=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,t);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);return t;});
    gl.uniform1i(this.uniforms.oldPage,0);gl.uniform1i(this.uniforms.newPage,1);
    this.canvas.addEventListener('webglcontextlost',()=>{KMReaderCurlSurface.shared=null;this.canvas.remove();});
  }
  upload(before,after,width,height) {
    const gl=this.gl,dpr=Math.min(2,devicePixelRatio||1);
    this.canvas.width=Math.round(width*dpr);this.canvas.height=Math.round(height*dpr);gl.viewport(0,0,this.canvas.width,this.canvas.height);
    [before,after].forEach((image,i)=>{gl.activeTexture(gl.TEXTURE0+i);gl.bindTexture(gl.TEXTURE_2D,this.textures[i]);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,image);});
    if(gl.getError()!==gl.NO_ERROR)throw Error('Page texture unavailable');
    gl.uniform2f(this.uniforms.size,width,height);
  }
  render(progress,spread,sign,slope,y,paper){const g=this.gl,u=this.uniforms;g.uniform1f(u.progress,progress);g.uniform1f(u.spread,spread?1:0);g.uniform1f(u.sign,sign);g.uniform1f(u.slope,slope);g.uniform1f(u.grabY,y);g.uniform3fv(u.paper,paper);g.drawArrays(g.TRIANGLE_STRIP,0,4);}
}
class KMReaderSheetEffect {
  static serial=0;
  static supported(style='slide'){return style==='curl'?typeof WebGLRenderingContext!=='undefined':typeof document.startViewTransition==='function';}
  constructor(style,sign,preferences,y=.5,reverse=false,spread=false,capture=null){
    Object.assign(this,{style,sign,preferences,y,reverse,spread,capture});
    this.width=innerWidth;this.height=innerHeight;this.progress=0;this.slope=0;this.id=`km-sheet-${++KMReaderSheetEffect.serial}`;
  }
  async start(move){
    if(this.style==='curl'){
      let moved=false;
      try{
        const before=await this.capture();
        if(this.stopped)return false;
        this.surface=KMReaderCurlSurface.shared??=new KMReaderCurlSurface();
        this.surface.upload(before,before,this.width,this.height);this.update(0);document.body.append(this.surface.canvas);
        moved=true;await move();
        const after=await this.capture();if(this.stopped)return false;
        this.surface.upload(this.reverse?after:before,this.reverse?before:after,this.width,this.height);this.update(0);return true;
      }catch(_){if(!moved)await move();this.stop();return false;}
    }
    this.sheet=document.createElement('style');this.sheet.dataset.pageMotion=this.id;
    this.sheet.textContent=`::view-transition{pointer-events:none}:root{view-transition-name:none}#viewer{view-transition-name:km-reader-page}
      ::view-transition-group(km-reader-page){animation:none}
      ::view-transition-old(km-reader-page),::view-transition-new(km-reader-page){animation:km-sheet-hold 30s linear both paused;mix-blend-mode:normal;transform-origin:center;object-fit:fill;overflow:hidden}
      @keyframes km-sheet-hold{from{opacity:1}to{opacity:1}}`;
    this.frames=document.createElement('style');this.frames.dataset.pageMotionFrame=this.id;document.head.append(this.sheet,this.frames);
    let moved=false;
    try{this.transition=document.startViewTransition(async()=>{moved=true;await move();});this.transition.finished.then(()=>this.stop(),()=>this.stop());this.transition.updateCallbackDone.catch(()=>{});await this.transition.ready;this.update(0);return true;}
    catch(_){if(this.transition)await this.transition.updateCallbackDone.catch(()=>{});if(!moved)await move();this.stop();return false;}
  }
  update(value,point){
    if(this.stopped)return;
    const p=this.progress=Math.max(0,Math.min(1,value));
    if(point){const dx=Math.max(this.width*.15,p*this.width);this.slope=Math.max(-.65,Math.min(.65,-(point.y-this.y*this.height)/dx));}
    if(this.style==='curl'){
      if(this.surface){const hex=this.preferences.backgroundColor||(this.preferences.theme==='black'?'#1c1c1e':this.preferences.theme==='white'?'#ffffff':'#efe5d0');const paper=[1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)/255);this.surface.render(this.reverse?1-p:p,this.spread,this.reverse?-this.sign:this.sign,this.slope*Math.sin(Math.PI*p),this.y,paper);}return;
    }
    const upperOld=this.style==='slide'?!this.reverse:false;
    const travel=this.style==='cover'?this.sign*(1-p)*100:upperOld?-this.sign*p*100:this.sign*(1-p)*100;
    const parallax=this.style==='cover'?0:upperOld?this.sign*(1-p)*10:-this.sign*p*10;
    const phase=upperOld?p:1-p;
    const dark=(this.preferences.backgroundColor||'').match(/^#([0-9a-f]{6})$/i)?.[1];
    const isDark=this.preferences.theme==='black'||dark&&parseInt(dark.slice(0,2),16)<90;
    const tint=isDark?Math.min(.12,Math.max(0,Number(this.preferences.pageTint)||0))*Math.pow(Math.max(0,(phase-.25)/.75),2.4):0;
    const dim=.12*Math.pow(upperOld?1-p:p,1.6);
    const radius=(Number(this.preferences.pageCornerRadius)||0)*Math.min(1,phase*12);
    const lift=`contrast(${1-tint}) brightness(${1+tint*.5})`;
    const under=`brightness(${1-dim})`;
    this.frames.textContent=`::view-transition-old(km-reader-page){transform:translateX(${upperOld?travel:parallax}%);z-index:${upperOld?2:1};filter:${upperOld?lift:under};border-radius:${upperOld?radius:0}px}
      ::view-transition-new(km-reader-page){transform:translateX(${upperOld?parallax:travel}%);z-index:${upperOld?1:2};filter:${upperOld?under:lift};border-radius:${upperOld?0:radius}px}`;
  }
  animateTo(target,duration){if(this.stopped)return Promise.resolve();this.finishAnimation?.();cancelAnimationFrame(this.frame);return new Promise(resolve=>{this.finishAnimation=resolve;const from=this.progress,start=performance.now();const frame=now=>{if(this.stopped){resolve();return;}const t=Math.min(1,(now-start)/Math.max(1,duration));const eased=1-Math.pow(1-t,4);this.update(from+(target-from)*eased);if(t<1)this.frame=requestAnimationFrame(frame);else{this.finishAnimation=null;resolve();}};this.frame=requestAnimationFrame(frame);});}
  stop(){if(this.stopped)return;this.stopped=true;cancelAnimationFrame(this.frame);this.finishAnimation?.();this.finishAnimation=null;this.transition?.skipTransition();this.sheet?.remove();this.frames?.remove();this.surface?.canvas.remove();}
}


(() => {
  let book, rendition, config, preferences, location, auxiliary, anchor;
  let renditionSpineHooks = [], operationQueue = Promise.resolve(), turnAnimation, sheetEffect, gesture;
  let interactiveNavigation = false, suppressClickUntil = 0, inputSuspended = false;
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
      ::selection{background:rgba(75,135,230,.38);color:inherit;}img,svg,video{max-width:100% !important;object-fit:contain;}a{color:${preferences.theme === 'black' ? '#9fc6ff' : '#235a9c'};}`;
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
    const clearSelection = () => doc.getSelection()?.removeAllRanges();
    if (preferences.flow === 'scrolled' && rendition.manager?.stage) {
      // The first CJK view can change the manager axis after its stage chose
      // overflow-x/y. Reapply that policy so the new axis accepts input.
      const manager = rendition.manager;
      manager.stage.overflow(manager.overflow || 'scroll');
    }
    doc.addEventListener('click', event => {
      if (inputSuspended || Date.now() < suppressClickUntil) { event.preventDefault(); event.stopImmediatePropagation(); return; }
      const link = event.target.closest && event.target.closest('a[href]');
      if (link) {
        event.preventDefault(); event.stopImmediatePropagation();
        send('link', {href: link.href, base: section.href});
      } else if (doc.getSelection().isCollapsed) {
        const bounds = doc.defaultView.frameElement.getBoundingClientRect();
        send('tap', {pointerType: event.pointerType || 'mouse', x: (bounds.left + event.clientX) / window.innerWidth, y: (bounds.top + event.clientY) / window.innerHeight});
      }
    }, true);
    doc.addEventListener('keydown', event => {
      if (inputSuspended || event.ctrlKey || event.metaKey || event.altKey) return;
      if (event.key === 'Escape' && !doc.getSelection().isCollapsed) { clearSelection(); event.preventDefault(); return; }
      if (!doc.getSelection().isCollapsed && !['ArrowLeft','ArrowRight','PageDown','PageUp','F11'].includes(event.key)) return;
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
      if (inputSuspended) { event.preventDefault(); return; }
      const p = point(event);
      if (event.pointerType === 'mouse') {
        // caretRangeFromPoint snaps to the nearest paragraph even in margins.
        // Only a hit on a real glyph may start a native text selection.
        const caret = doc.caretRangeFromPoint?.(event.clientX,event.clientY);
        let textHit = false;
        if (caret?.startContainer.nodeType === Node.TEXT_NODE) {
          const range = caret.cloneRange(), node=caret.startContainer, offset=Math.min(caret.startOffset,Math.max(0,node.length-1));
          range.setStart(node,offset); range.setEnd(node,Math.min(node.length,offset+1));
          textHit=[...range.getClientRects()].some(r=>event.clientX>=r.left-2&&event.clientX<=r.right+2&&event.clientY>=r.top&&event.clientY<=r.bottom);
        }
        if (!textHit && !event.target.closest?.('a[href]')) { event.preventDefault(); clearSelection(); }
      }
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
      if (preferences.followGesture !== false && motionAllowed(preferences.transition) && KMReaderSheetEffect.supported(preferences.transition)) {
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
      if (inputSuspended) return;
      const selected = selection.isCollapsed ? '' : selection.toString().trim().slice(0,16000);
      clearTimeout(doc._selectionReport);
      doc._selectionReport=setTimeout(()=>send('selection',{text:selected}),80);
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
      cancelTurnAnimation(); preferences = value; warmCurl(); return;
    }
    captureRevision++;capturePages.clear();
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
  const captureMarkup=new WeakMap(),capturePages=new Map(),captureResources=new Map();
  let captureSerial=0,captureRevision=0,captureIdle,captureResourceBytes=0;
  const captureResourceSizes=new Map();
  async function embeddedResource(value,base){
    if(!value||value.startsWith('data:')||value.startsWith('#'))return value;
    const url=new URL(value,base);if(url.origin!==locationOrigin())throw Error('External page artwork');
    if(!captureResources.has(url.href)){
      const task=fetch(url.href).then(r=>{if(!r.ok)throw Error('Artwork unavailable');return r.blob();}).then(blob=>{
        if(blob.size>32*1024*1024)throw Error('Artwork exceeds snapshot budget');
        if(captureResources.has(url.href)){captureResourceSizes.set(url.href,blob.size);captureResourceBytes+=blob.size;}
        while(captureResourceBytes>48*1024*1024&&captureResources.size>1){
          const old=captureResources.keys().next().value;
          captureResources.delete(old);captureResourceBytes-=captureResourceSizes.get(old)||0;captureResourceSizes.delete(old);
        }
        return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=reject;reader.readAsDataURL(blob);});
      });
      if(captureResources.size>=24){const old=captureResources.keys().next().value;captureResources.delete(old);captureResourceBytes-=captureResourceSizes.get(old)||0;captureResourceSizes.delete(old);}
      captureResources.set(url.href,task);
    }
    return captureResources.get(url.href);
  }
  const locationOrigin=()=>window.location.origin;
  async function embedCss(text,base){
    const matches=[...text.matchAll(/url\(\s*(['"]?)(.*?)\1\s*\)/g)];
    for(const match of matches)text=text.replace(match[0],`url("${await embeddedResource(match[2],base)}")`);
    return text;
  }
  async function cssSheet(sheet,base){
    const rules=[...sheet.cssRules];
    return (await Promise.all(rules.map(rule=>rule.styleSheet?cssSheet(rule.styleSheet,rule.styleSheet.href||base):embedCss(rule.cssText,sheet.href||base)))).join('\n');
  }
  async function sheetMarkup(frame){
    const doc=frame.contentDocument,box=frame.getBoundingClientRect();
    const signature=[captureRevision,box.width,box.height,doc.body.getAttribute('style'),doc.documentElement.getAttribute('style')].join('|');
    const cached=captureMarkup.get(doc);if(cached?.signature===signature)return cached;
    const value={signature,id:++captureSerial};
    value.work=(async()=>{
      const root=doc.documentElement.cloneNode(true);
      root.querySelectorAll('script,link,base,meta,style').forEach(n=>n.remove());
      const css=(await Promise.all([...doc.styleSheets].map(sheet=>cssSheet(sheet,doc.baseURI)))).join('\n');
      const style=doc.createElement('style');style.textContent=css+'\n*{caret-color:transparent!important}::selection{background:transparent!important}';root.querySelector('head').append(style);
      const original=doc.querySelectorAll('img'),clones=root.querySelectorAll('img');
      await Promise.all([...clones].map(async(img,i)=>{const url=original[i].currentSrc||original[i].src;if(url)img.setAttribute('src',await embeddedResource(url,doc.baseURI));img.removeAttribute('srcset');img.removeAttribute('loading');}));
      await Promise.all([...root.querySelectorAll('image')].map(async(img)=>{const url=img.getAttribute('href')||img.getAttributeNS('http://www.w3.org/1999/xlink','href');if(url){const data=await embeddedResource(url,doc.baseURI);img.setAttribute('href',data);img.removeAttributeNS('http://www.w3.org/1999/xlink','href');}}));
      root.querySelector('body').style.setProperty('overflow','visible','important');root.style.setProperty('overflow','visible','important');
      root.setAttribute('xmlns','http://www.w3.org/1999/xhtml');root.style.width=box.width+'px';root.style.height=box.height+'px';
      return new XMLSerializer().serializeToString(root);
    })();captureMarkup.set(doc,value);return value;
  }
  async function captureSheet(shift=0){
    const width=innerWidth,height=innerHeight,dpr=Math.min(2,devicePixelRatio||1),revision=captureRevision;
    const frames=[...document.querySelectorAll('#viewer iframe')].filter(f=>{const b=f.getBoundingClientRect();return b.right>0&&b.left<width&&b.bottom>0&&b.top<height;});
    const parts=await Promise.all(frames.map(async frame=>{const r=frame.getBoundingClientRect();return {box:{x:r.x+shift,y:r.y,width:r.width,height:r.height},markup:await sheetMarkup(frame)};}));
    if(!parts.length)throw Error('No visible publication');
    const key=JSON.stringify([width,height,dpr,...parts.map(p=>[p.markup.id,p.box.x,p.box.y])]);
    if(capturePages.has(key)){const value=capturePages.get(key);capturePages.delete(key);capturePages.set(key,value);return value;}
    const task=(async()=>{
      const layers=await Promise.all(parts.map(async({box,markup})=>`<foreignObject x="${box.x}" y="${box.y}" width="${box.width}" height="${box.height}">${await markup.work}</foreignObject>`));
      const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${Math.round(width*dpr)}" height="${Math.round(height*dpr)}" viewBox="0 0 ${width} ${height}"><rect width="100%" height="100%" fill="${colors()[0]}"/>${layers.join('')}</svg>`;
      if(svg.length>8*1024*1024)throw Error('Page texture exceeds markup budget');
      const image=new Image();image.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg);await image.decode();
      if(disposed||revision!==captureRevision)throw Error('Stale page texture');return image;
    })();capturePages.set(key,task);task.catch(()=>capturePages.delete(key));
    // Four screen-sized textures at most; document markup is shared per chapter.
    const limit=Math.max(2,Math.min(4,Math.floor(32*1024*1024/(width*height*dpr*dpr*4))));
    while(capturePages.size>limit)capturePages.delete(capturePages.keys().next().value);
    return task;
  }
  function warmCurl(){
    clearTimeout(captureIdle);
    if(inputSuspended||preferences.transition!=='curl'||!motionAllowed('curl'))return;
    captureIdle=setTimeout(async()=>{
      if(disposed||inputSuspended||gesture||sheetEffect)return;
      try {
        await captureSheet();
        if(disposed||inputSuspended||gesture||sheetEffect||rendition?.manager?.settings.axis!=='horizontal')return;
        const frames=[...document.querySelectorAll('#viewer iframe')];
        if(frames.length!==1)return;
        const bounds=frames[0].getBoundingClientRect();
        // Prepare adjacent positions without navigating, layout or progress
        // writes. Actual turns reuse these textures by viewport geometry.
        for(const shift of [-innerWidth,innerWidth]){
          if(disposed||inputSuspended||gesture||sheetEffect)return;
          if(bounds.left+shift<=0&&bounds.right+shift>=innerWidth)await captureSheet(shift);
        }
      }catch(_){/* Unsupported artwork retains direct reading. */}
    },100);
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
      state.point=p;state.effect?.update(state.progress,p);
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
        state.effect?.update(state.progress,state.point);
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
    if (!motionAllowed(style) || !KMReaderSheetEffect.supported(style) || (delta > 0 && atReadingEnd())) {
      await move(); return null;
    }
    await tick();
    const effect = sheetEffect = new KMReaderSheetEffect(style,
      (delta > 0) !== (config.direction === 'rtl') ? 1 : -1, preferences, y, delta < 0, rendition.manager?.layout?.divisor === 2, captureSheet);
    if (!await effect.start(() => capturedLayout(move))) { if (sheetEffect === effect) sheetEffect = undefined; return null; }
    return effect;
  }
  async function turn(value) {
    if (!rendition || auxiliary) return;
    for (const contents of rendition.getContents()) contents.document.getSelection()?.removeAllRanges();
    cancelTurnAnimation();
    const effect = await transitionMove(value.delta, value.style || preferences.transition, .5);
    if (!effect || disposed) return;
    // Navigation is already committed. Cosmetic motion never owns the input
    // queue, and the next input can replace this compositor transition.
    const duration = Math.max(150, Math.min(900, Number(preferences.animationDuration) || 380));
    effect.animateTo(1, duration).then(() => {
      effect.stop(); if (sheetEffect === effect) sheetEffect = undefined; warmCurl();
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
    config = value; preferences = value.preferences; restoring = true; captureRevision++;capturePages.clear();captureResources.clear();captureResourceSizes.clear();captureResourceBytes=0;
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
    // A native WebView can attach its remaining spread view after display's
    // first completion. Keep the verified initial layout barrier; archive
    // preparation is optimized independently of native first-paint readiness.
    await stable(rendition.getContents());
    if (!restoredCfi && value.progression > 0) await legacyProgress(value.progression);
    await tick();
    // Ready must describe a real viewport, even if the initial relocated
    // callback is still queued by the renderer.
    refreshViewportLocation();
    restoring = false; userMove = false; anchor = restoredCfi ? value.cfi : (location && location.start.cfi);
    position(false); warmCurl(); send('ready', {layout: isFixedLayout() ? 'pre-paginated' : 'reflowable', writingMode: rendition.manager?.writingMode || 'horizontal-tb'});
    window.addEventListener('resize', onResize);
    for (const event of inputEvents) document.addEventListener(event, noteUserMove, {passive: true});
  }
  function onResize() {
    cancelGesture();
    captureRevision++;capturePages.clear();
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
    suspendInput: value => {
      inputSuspended=!!value;clearTimeout(captureIdle);cancelGesture();cancelTurnAnimation();
      for(const c of rendition?.getContents()||[]) c.document.getSelection()?.removeAllRanges();
      if(inputSuspended)return true;
      // Android delivers native surface bounds/focus after the sheet closes.
      // Settle that delivery once here, ahead of queued turns, not per page.
      return enqueue(async()=>{await tick();await waitForLayout();warmCurl();return true;});
    },
    selectedText: () => (rendition?.getContents()||[]).map(c=>c.document.getSelection()?.toString()||'').find(text=>text.trim())||'',
    clearSelection: () => {for(const c of rendition?.getContents()||[]) c.document.getSelection()?.removeAllRanges();return true;},
    position: () => location, layoutReady,
    whenIdle: () => enqueue(waitForLayout), destroy: () => {
      disposed = true; cancelGesture(); clearTimeout(relocationTimer); clearTimeout(resizeTimer); clearTimeout(captureIdle);captureRevision++;capturePages.clear();captureResources.clear();captureResourceSizes.clear();captureResourceBytes=0;
      cancelTurnAnimation();
      window.removeEventListener('resize', onResize);
      for (const event of inputEvents) document.removeEventListener(event, noteUserMove);
      destroyRendition(); if (book) book.destroy();
    }};
})();
