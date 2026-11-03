#!/usr/bin/env python3
"""Check visible compositor page effects, gesture tracking/cancel and fallbacks."""
import io
import json
import sys
from pathlib import Path
from PIL import Image, ImageChops
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
width, height = config['viewport']['width'], config['viewport']['height']
rtl = config.get('direction') == 'rtl'
def xcoord(x): return width - x if rtl else x
with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport=config['viewport'], has_touch=True)
    page.set_default_timeout(5000)
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.add_init_script("window.messages=[];addEventListener('readerEvent',e=>messages.push(e.detail));")
    page.goto(url)
    page.evaluate('(c)=>reader.open(c)', config)
    selected = page.evaluate("""() => {const doc=document.querySelector('#viewer iframe').contentDocument,p=doc.querySelector('p');doc.getSelection().selectAllChildren(p);doc.defaultView.dispatchEvent(new Event('blur'));return p.textContent;}""")
    assert page.evaluate('reader.selectedText()') == selected, 'Toolbar focus destroyed the selected passage'
    page.evaluate('reader.clearSelection()')
    assert page.evaluate('reader.selectedText()') == ''
    page.evaluate("""() => {
      window.boundaryStarts=0;
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=function(...args){boundaryStarts++;return start.apply(this,args);};
    }""")
    first_cfi=page.evaluate('reader.position().start.cfi')
    page.evaluate("reader.turn({delta:-1,style:'curl'})")
    assert page.evaluate('boundaryStarts') == 0, 'First page started a reverse animation'
    assert page.evaluate('reader.position().start.cfi') == first_cfi
    before_selection = page.evaluate('reader.position().start.cfi')
    # A genuine drag on text near the page edge selects words, not a page.
    page.evaluate('() => new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))')
    box = page.frames[1].locator('p').first.evaluate('''p => {
      const range=p.ownerDocument.createRange();range.setStart(p.firstChild,0);range.setEnd(p.firstChild,1);
      const r=range.getBoundingClientRect(),f=p.ownerDocument.defaultView.frameElement.getBoundingClientRect();
      return {x:r.x+f.x,y:r.y+f.y,width:r.width,height:r.height};
    }''')
    # Raw trusted pointer events avoid Playwright's native HTML drag interceptor
    # waiting for an unrelated text-drop operation across the wide book iframe.
    mouse_cdp=page.context.new_cdp_session(page)
    x,y=box['x']+box['width']*.7,box['y']+box['height']*.5
    mouse_cdp.send('Input.dispatchMouseEvent',{'type':'mouseMoved','x':x,'y':y,'buttons':0})
    mouse_cdp.send('Input.dispatchMouseEvent',{'type':'mousePressed','x':x,'y':y,'button':'left','buttons':1,'clickCount':1})
    for step in range(1,9):
        mouse_cdp.send('Input.dispatchMouseEvent',{'type':'mouseMoved','x':x+step*(78/8),'y':y,'button':'left','buttons':1})
    mouse_cdp.send('Input.dispatchMouseEvent',{'type':'mouseReleased','x':x+78,'y':y,'button':'left','buttons':0,'clickCount':1})
    mouse_cdp.detach()
    page.wait_for_timeout(150)
    assert page.evaluate('reader.selectedText().length')>0, 'Mouse text drag was treated as a page gesture'
    assert not page.evaluate('!!document.getElementById("page-gesture")'), 'Text selection started a turn'
    assert page.evaluate('reader.position().start.cfi')==before_selection
    page.evaluate('reader.clearSelection()')
    # Genuine mouse input in a margin must not create a phantom text selection.
    page.mouse.click(width*.5, 2)
    assert page.evaluate("document.querySelector('#viewer iframe').contentDocument.getSelection().isCollapsed")
    page.evaluate("reader.suspendInput(true)")
    page.evaluate("messages.length=0")
    page.evaluate("document.querySelector('#viewer iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}))")
    assert not page.evaluate("messages.some(e=>e.type==='turn'||e.type==='tap')")
    page.evaluate("reader.suspendInput(false)")
    page.evaluate('''() => {
      window.motionUpdate = KMReaderSheetEffect.prototype.update;
      window.motionAnimate = KMReaderSheetEffect.prototype.animateTo;
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=async function(move){window.effect=this;return start.call(this,move);};
      KMReaderSheetEffect.prototype.animateTo=function(){return new Promise(()=>{});};
    }''')
    output = Path('artifacts/epub-motion-0.8.10')
    output.mkdir(parents=True, exist_ok=True)
    for style in ['slide', 'cover', 'curl']:
        before = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        old = page.evaluate('reader.position().start.cfi')
        page.evaluate('(style)=>reader.turn({delta:1,style})', style)
        assert page.evaluate('!effect.stopped'), style
        assert page.evaluate('reader.position().start.cfi') != old
        page.evaluate('effect.update(.43)')
        image = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        image.save(output / f'{width}-{config.get("direction", "ltr")}-{style}.png')
        assert ImageChops.difference(before, image).getbbox(), style
        pixels = image.getdata()
        assert sum(max(p) < 120 for p in pixels) > 150, (style, 'Blank page')
        if style != 'curl':
            assert page.evaluate('effect.styles.every(s=>s.borderRadius === "") && effect.styles.some(s=>s.filter.startsWith("brightness(")) && effect.styles.some(s=>s.filter.startsWith("drop-shadow("))'), style
        if style == 'curl':
            assert page.evaluate('effect.surface.canvas.width') == width
            assert page.evaluate('effect.surface.canvas.height') == height
            # The unturned front must bend before the tight roll reaches it.
            # Compare glyph masks against the same GPU's flat endpoint, so
            # differences cannot come from DOM/SVG text antialiasing or shade.
            page.evaluate('effect.update(0)')
            flat=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
            page.evaluate('effect.update(.25)')
            bent=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
            leaf=width/2 if width>800 else width
            hinge=width/2 if width>800 else (width if rtl else 0)
            left,right=sorted([int(hinge+(-1 if rtl else 1)*leaf*f) for f in [.48,.64]])
            crop=(left,50,right,height-50)
            mask=lambda image:image.crop(crop).convert('L').point(lambda v:255 if v>120 else 0)
            changed=sum(v>0 for v in ImageChops.difference(mask(flat),mask(bent)).getdata())
            assert changed>40, 'Unturned text stayed flat until the fold arrived'
            # Full resolution GPU rendering: dragging never encodes/maps a PNG.
            page.evaluate("() => {window.originalEncoding=HTMLCanvasElement.prototype.toDataURL;HTMLCanvasElement.prototype.toDataURL=()=>{throw Error('Per-frame bitmap encoding');};}")
            page.evaluate('effect.update(.43,{x:innerWidth*.5,y:innerHeight*.2})')
            angled=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
            assert ImageChops.difference(image,angled).getbbox(), 'Curl does not follow the vertical drag'
            page.evaluate('() => {HTMLCanvasElement.prototype.toDataURL=originalEncoding;}')
            page.evaluate('effect.update(1)')
            end=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
            page.evaluate('effect.stop()')
            live=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
            # Native glyphs and texture endpoints must agree; tiny text-AA
            # differences are expected between DOM and SVG rasterization.
            from PIL import ImageStat
            assert max(ImageStat.Stat(ImageChops.difference(end,live)).mean)<6, 'Curl endpoint changed the publication layout'
        if style != 'curl':
            assert page.evaluate('document.querySelectorAll("style[data-page-motion]").length') == 1
        page.evaluate('effect.stop()')
    # Backward turns peel the other leaf; they must not play a forward curl
    # in reverse time on the same side of the spine.
    page.evaluate("reader.turn({delta:-1,style:'curl'})")
    page.evaluate('effect.update(0)')
    reverse_flat=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
    page.evaluate('effect.update(.25)')
    reverse_bent=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
    reverse_bent.save(output / f'{width}-{config.get("direction", "ltr")}-curl-backward.png')
    if width>800:
        static=(0,40,width//4,height-40) if rtl else (width*3//4,40,width,height-40)
        # This leaf remains stationary and retains the old publication.
        difference=ImageChops.difference(reverse_flat.crop(static),reverse_bent.crop(static))
        assert max(ImageStat.Stat(difference).mean)<1, 'Backward curl moved the wrong leaf'
    page.evaluate('effect.update(1)')
    reverse_end=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
    page.evaluate('effect.stop()')
    reverse_live=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
    assert max(ImageStat.Stat(ImageChops.difference(reverse_end,reverse_live)).mean)<6
    page.evaluate('(p)=>reader.preferences({...p,backgroundColor:"#382E25",textColor:"#E3D5C1"})',config['preferences'])
    page.evaluate("reader.turn({delta:1,style:'curl'})")
    page.evaluate('(p)=>effect.update(.52,{x:innerWidth*.48,y:innerHeight*.73})')
    page.screenshot(path=str(output / f'{width}-{config.get("direction", "ltr")}-curl-sepia.png'))
    page.evaluate('effect.stop()')
    page.evaluate('(p)=>reader.preferences(p)',config['preferences'])
    # A raised free paper edge must cast its own shadow, away from the roll
    # ridge. White textures isolate actual lighting from text/ink differences.
    shadow=page.evaluate('''() => {
      const surface=effect.surface,g=surface.gl,stock=document.createElement('canvas');
      stock.width=innerWidth;stock.height=innerHeight;
      const c=stock.getContext('2d');c.fillStyle='#fff';c.fillRect(0,0,stock.width,stock.height);
      surface.upload(stock,stock,innerWidth,innerHeight);document.body.append(surface.canvas);
      surface.render(.68,true,-1,-.1,.5,.18);
      const width=surface.canvas.width,height=surface.canvas.height;
      const pixels=new Uint8Array(width*height*4);g.readPixels(0,0,width,height,g.RGBA,g.UNSIGNED_BYTE,pixels);
      const mask=surface.shadowTargets[0];g.bindFramebuffer(g.FRAMEBUFFER,mask.fbo);
      const shadows=new Uint8Array(surface.maskWidth*surface.maskHeight*4);
      g.readPixels(0,0,surface.maskWidth,surface.maskHeight,g.RGBA,g.UNSIGNED_BYTE,shadows);g.bindFramebuffer(g.FRAMEBUFFER,null);
      let exposed=0;
      for(let y=0;y<height;y++)for(let x=0;x<width;x++){
        const i=(y*width+x)*4,m=(Math.min(surface.maskHeight-1,Math.floor(y*surface.maskHeight/height))*surface.maskWidth+Math.min(surface.maskWidth-1,Math.floor(x*surface.maskWidth/width)))*4;
        const value=pixels[i],shadow=shadows[m];
        if(shadow>5&&value>180&&value<250&&Math.abs(value-(255-shadow))<4&&Math.max(...pixels.slice(i,i+3))-Math.min(...pixels.slice(i,i+3))<=1)exposed++;
      }
      const error=g.getError();surface.canvas.remove();return {exposed,error};
    }''')
    assert shadow['error']==0 and shadow['exposed']>50, ('Missing smooth projected paper shadow',shadow)
    seam=page.evaluate('''() => {
  const surface=effect.surface,g=surface.gl,stock=document.createElement('canvas');
  stock.width=innerWidth;stock.height=innerHeight;
  const c=stock.getContext('2d');c.fillStyle='#fff';c.fillRect(0,0,stock.width,stock.height);
  surface.upload(stock,stock,innerWidth,innerHeight);
  const width=surface.canvas.width,height=surface.canvas.height;
  const black=g.createTexture();g.activeTexture(g.TEXTURE3);g.bindTexture(g.TEXTURE_2D,black);
  g.texImage2D(g.TEXTURE_2D,0,g.RGBA,1,1,0,g.RGBA,g.UNSIGNED_BYTE,new Uint8Array([0,0,0,255]));
  g.texParameteri(g.TEXTURE_2D,g.TEXTURE_MIN_FILTER,g.NEAREST);
  const bind=(program,buffer)=>{g.useProgram(program.p);g.bindBuffer(g.ARRAY_BUFFER,buffer);g.enableVertexAttribArray(program.a);g.vertexAttribPointer(program.a,2,g.FLOAT,false,0,0);};
  const sample=()=>{const out=new Uint8Array(4);g.readPixels(Math.floor(width/2)+2,Math.floor(height/2),1,1,g.RGBA,g.UNSIGNED_BYTE,out);return out[0];};
  const results=[];
  for(const p of [.5,.55,.6,.65]){
    surface.render(p,true,1,0,.5);
    const draw=receiver=>{
      g.disable(g.DEPTH_TEST);bind(surface.background,surface.quad);g.drawArrays(g.TRIANGLE_STRIP,0,4);
      const background=sample();
      g.clear(g.DEPTH_BUFFER_BIT);g.enable(g.DEPTH_TEST);g.enable(g.CULL_FACE);g.cullFace(g.BACK);
      bind(surface.sheet,surface.mesh);g.uniform1i(surface.sheet.u.castShadow,receiver);
      g.bindBuffer(g.ELEMENT_ARRAY_BUFFER,surface.indices);g.drawElements(g.TRIANGLES,surface.count,g.UNSIGNED_SHORT,0);
      const front=sample();g.disable(g.CULL_FACE);g.disable(g.DEPTH_TEST);return {background,front};
    };
    const fixed=draw(2),old=draw(3);
    // Read the broad shadow edge on a plain receiving surface, excluding the
    // folded sheet so paper geometry cannot hide the gradient's extent.
    bind(surface.background,surface.quad);g.drawArrays(g.TRIANGLE_STRIP,0,4);
    const row=new Uint8Array(width*4);g.readPixels(0,Math.floor(height/2),width,1,g.RGBA,g.UNSIGNED_BYTE,row);
    const shade=Array.from({length:width},(_,x)=>255-row[x*4]),peak=Math.max(...shade);
    const start=shade.findIndex(v=>v>=peak*.1),end=shade.findIndex(v=>v>=peak*.8);
    let run=0,plateau=0;
    for(let x=start+1;x<=end;x++){run=shade[x]===shade[x-1]?run+1:0;plateau=Math.max(plateau,run);}
    results.push({p,fixed,old,peak,plateau,edgePixels:end-start,edgeWidth:(end-start)*innerWidth/width});
  }
  g.useProgram(surface.sheet.p);g.uniform1i(surface.sheet.u.castShadow,2);g.deleteTexture(black);
  surface.render(0,true,1,0,.5);return {results,error:g.getError()};
}
''')
    (output / f'{width}-shadow-probe.json').write_text(json.dumps(seam,indent=2))
    assert seam['error']==0, seam
    for sample in seam['results']:
        assert abs(sample['fixed']['background']-sample['fixed']['front'])<=2, ('Shadow interrupted at flat receiver',sample)
        assert sample['old']['front']-sample['old']['background']>60, ('Regression control cannot detect missing receiver',sample)
        assert sample['peak']>=75 and sample['edgeWidth']>=10+width*.01, ('Shadow too faint or narrow',sample)
        assert sample['plateau']<=max(2, sample['edgePixels']*.08), ('Shadow has repeated bands',sample)
    page.evaluate('''async () => {const surface=effect.surface,g=surface.gl;
  const originalUpload=g.texImage2D;let uploads=0;
  g.texImage2D=function(...args){uploads++;return originalUpload.apply(this,args);};
  try {
    const pages=Array.from({length:4},(_,i)=>{const page=document.createElement('canvas');page.width=64;page.height=64;const c=page.getContext('2d');c.fillStyle=['red','green','blue','white'][i];c.fillRect(0,0,64,64);return page;});
    const counts=[];
    for(const [front,back] of [[pages[0],pages[1]],[pages[1],pages[2]],[pages[2],null],[pages[2],pages[3]]]){
      uploads=0;surface.upload(front,back,innerWidth,innerHeight);counts.push(uploads);
    }
    if(counts.join(',')!=='2,1,0,1')throw Error('Sequential page textures uploaded again: '+counts);
    surface.render(0,true,1,0,.5);
    const pixel=new Uint8Array(4);g.readPixels(0,0,1,1,g.RGBA,g.UNSIGNED_BYTE,pixel);
    if(pixel[2]<250||pixel[0]>2)throw Error('Texture rotation selected the wrong front: '+pixel);
    // Exercise the complete production start, not only the texture cache API.
    // Its initial frame reads the front only; mirroring it into the back would
    // upload that same page again immediately before loading the new back.
    const savedEffect=window.effect,savedNative=window.nativeCurl,queue=[pages[3],pages[0]];
    const real=new KMReaderSheetEffect('curl',1,{},.5,false,true,async()=>queue.shift());
    uploads=0;
    try {
      if(!await real.start(async()=>{}))throw Error('Real curl start unavailable');
      if(uploads!==1)throw Error('Real curl start reuploaded a retained front: '+uploads);
      real.update(0);g.readPixels(0,0,1,1,g.RGBA,g.UNSIGNED_BYTE,pixel);
      if(pixel[0]<250||pixel[1]<250||pixel[2]<250)throw Error('Real curl start selected the wrong front');
      real.update(1);g.readPixels(0,0,1,1,g.RGBA,g.UNSIGNED_BYTE,pixel);
      if(pixel[0]<250||pixel[1]>2||pixel[2]>2)throw Error('Real curl start selected the wrong back');
    } finally {real.stop();window.effect=savedEffect;window.nativeCurl=savedNative;}

  } finally {g.texImage2D=originalUpload;}
}''')
    timing=page.evaluate('''async () => {
  const original=requestAnimationFrame,cancel=cancelAnimationFrame;
  const values=[],queue=[];
  let count=0;
  window.requestAnimationFrame=callback=>{queue.push(callback);return ++count;};
  window.cancelAnimationFrame=()=>{};
  try {
    const sheet=Object.create(KMReaderSheetEffect.prototype);
    sheet.style='curl';sheet.progress=0;sheet.update=p=>{sheet.progress=p;values.push(p);};
    const finished=motionAnimate.call(sheet,1,380,{automatic:true});
    let now=1000;
    queue.shift()(now);queue.shift()(now+=16);queue.shift()(now+=200);
    const delayed=values.at(-1);
    while(queue.length&&values.length<100)queue.shift()(now+=16);
    await finished;
    sheet.progress=.4;const released=[];sheet.update=p=>{sheet.progress=p;released.push(p);};
    const release=motionAnimate.call(sheet,1,240,{velocity:.0015});
    while(queue.length&&released.length<100)queue.shift()(now+=16);
    await release;
    return {first:values[0],delayed,last:values.at(-1),monotone:values.every((v,i)=>!i||v>=values[i-1]),
      releaseFirst:released[0],releaseDelta:released[1]-released[0],releaseLast:released.at(-1),
      releaseMonotone:released.every((v,i)=>v<=1&&(!i||v>=released[i-1]))};
  } finally {window.requestAnimationFrame=original;window.cancelAnimationFrame=cancel;}
}
''')
    assert timing['first']==0 and timing['delayed']<.02 and timing['last']==1 and timing['monotone'], timing
    assert timing['releaseFirst']==.4 and .02<timing['releaseDelta']<.04 and timing['releaseLast']==1 and timing['releaseMonotone'],timing
    page.evaluate('() => { KMReaderSheetEffect.prototype.animateTo=motionAnimate; }')
    # Native-style no-op snapshot also exposes intermediate automatic frames.
    # Sample delivered frames so a delayed timer cannot miss an entire turn.
    automatic=page.evaluate('''async () => {
      const sheet=new KMReaderSheetEffect('slide',1,{},.5,false,false);
      if(!await sheet.start(async()=>{}))throw Error('Automatic snapshot unavailable');
      const finished=sheet.animateTo(1,380,{automatic:true}),samples=[];
      for(let frame=0;frame<120;frame++){
        await new Promise(requestAnimationFrame);samples.push(sheet.progress);
        if(sheet.progress>0&&sheet.progress<1)break;
        if(sheet.stopped||sheet.progress>=1)break;
      }
      await finished;sheet.stop();return samples;
    }''')
    assert any(0<p<1 for p in automatic), automatic
    # Actual automatic effects remain visible mid-flight, not just a retained
    # JS object after Chromium already removed its snapshot pseudo-elements.
    page.evaluate("reader.turn({delta:1,style:'slide'})")
    page.wait_for_timeout(100)
    assert page.evaluate("document.getAnimations().some(a=>a.effect?.pseudoElement?.startsWith('::view-transition-'))"), 'Automatic effect vanished too early'
    assert page.evaluate('effect.progress') > 0
    assert page.evaluate('effect.compositor?.animations.length===2'), 'Slide is not animated by the snapshot compositor'
    page.mouse.click(width*.5, 2)
    assert not page.evaluate('document.querySelector("style[data-page-motion]") || document.getElementById("page-curl-surface")'), 'Mouse input did not expose the live publication'
    page.evaluate("reader.turn({delta:1,style:'slide'})")
    page.wait_for_timeout(100)
    page.evaluate('reader.suspendInput(true)')
    assert not page.evaluate('document.querySelector("style[data-page-motion]") || document.getElementById("page-curl-surface")')
    page.evaluate('reader.suspendInput(false)')
    page.wait_for_function('() => !document.querySelector("style[data-page-motion]")')
    page.evaluate('(p)=>reader.preferences({...p,transition:"curl"})', config['preferences'])
    # Use real pointer capture within the original iframe document.
    saved = page.evaluate('reader.position().start.cfi')
    saved_page = page.evaluate('reader.position().start.displayed.page')
    page.evaluate('messages.length=0')
    page.mouse.move(xcoord(width - 6), height * .55)
    page.mouse.down()
    page.mouse.move(xcoord(width * .55), height * .55, steps=12)
    page.wait_for_function('() => document.getElementById("page-gesture") && window.effect && !effect.stopped')
    page.wait_for_timeout(100)
    progress = page.evaluate('effect.progress')
    assert (.60 < progress < 1 if width>800 else .30 < progress < .55), progress
    assert not page.evaluate('messages.some(e=>e.type==="position"&&e.changed)'), 'Gesture preview wrote progress'
    if width == 390 and not rtl:
        for step in range(22):
            page.wait_for_timeout(500)
            page.mouse.move(xcoord(width * (.55 + .015 * (step % 2))), height * (.55 + .008 * (step % 3)))
            assert page.evaluate('!!document.getElementById("page-gesture") && !effect.stopped'), 'A held active gesture expired'
        assert not page.evaluate('messages.some(e=>e.type==="position"&&e.changed)'), 'Held fold committed before release'

    page.mouse.move(xcoord(width * .35), height * .52, steps=4)
    assert page.evaluate('effect.progress') > progress
    page.mouse.up()
    page.wait_for_function('() => !document.getElementById("page-gesture")')
    assert page.evaluate('reader.position().start.cfi') != saved
    assert page.evaluate('reader.position().start.displayed.page') > saved_page
    assert page.evaluate('messages.filter(e=>e.type==="position"&&e.changed).length') == 1
    page.evaluate('''() => {
      const stop=KMReaderSheetEffect.prototype.stop;
      KMReaderSheetEffect.prototype.stop=function(){
        if(window.cancelAnchor && !this.stopped)window.cancelStops.push(reader.position().start.cfi);
        return stop.call(this);
      };
    }''')
    for cancel_style in ['slide','curl']:
        page.evaluate('(v)=>reader.preferences({...v,transition:"' + cancel_style + '"})', config['preferences'])
        saved = page.evaluate('reader.position().start.cfi')
        page.evaluate('(c)=>{window.cancelAnchor=c;window.cancelStops=[];messages.length=0;}',saved)
        page.mouse.move(xcoord(width - 6), height * .55)
        page.mouse.down()
        page.mouse.move(xcoord(width * .84), height * .55, steps=7)
        page.wait_for_timeout(100)
        page.mouse.move(xcoord(width * .97), height * .55, steps=6)
        page.mouse.up()
        page.wait_for_function('() => !document.getElementById("page-gesture")')
        assert page.evaluate('reader.position().start.cfi') == saved, 'Canceled drag changed CFI'
        assert page.evaluate('cancelStops') == [saved], 'Snapshot removed before the original publication was restored'
        assert not page.evaluate('messages.some(e=>e.type==="position"&&e.changed)'), 'Canceled drag wrote progress'
        page.evaluate('window.cancelAnchor=null')
    page.evaluate('(v)=>reader.preferences({...v,transition:"curl"})', config['preferences'])
    page.evaluate('window.retainedFrame=document.querySelector("#viewer iframe")')
    # Resize during a held gesture must cancel and retain the saved character.
    page.mouse.move(xcoord(width - 6), height * .55)
    page.mouse.down()
    page.mouse.move(xcoord(width * .65), height * .55, steps=7)
    page.wait_for_timeout(100)
    page.set_viewport_size({'width': width, 'height': height - 60})
    page.mouse.up()
    page.wait_for_function('() => !document.getElementById("page-gesture")')
    assert page.evaluate('reader.position().start.cfi') == saved
    if width == 390:
        # Real touch input (implicit capture), including a second-finger cancel.
        cdp = page.context.new_cdp_session(page)
        def touch(kind, points):
            cdp.send('Input.dispatchTouchEvent', {'type':kind,'touchPoints':[{'x':xcoord(x),'y':y,'id':i} for i,x,y in points]})
        h = height - 60
        saved = page.evaluate('reader.position().start.cfi')
        page.evaluate('messages.length=0')
        touch('touchStart', [(1,width-8,h*.55)])
        for fraction in [.9,.8,.7,.6,.5]:
            touch('touchMove', [(1,width*fraction,h*.55)])
        page.wait_for_timeout(100)
        assert page.evaluate('!!document.getElementById("page-gesture")')
        assert not page.evaluate('messages.some(e=>e.type==="position"&&e.changed)')
        touch('touchEnd', [])
        page.wait_for_function('() => !document.getElementById("page-gesture")')
        assert page.evaluate('reader.position().start.cfi') != saved
        saved = page.evaluate('reader.position().start.cfi')
        page.evaluate('messages.length=0')
        touch('touchStart', [(1,width-8,h*.55)])
        touch('touchMove', [(1,width*.6,h*.55)])
        page.wait_for_timeout(100)
        touch('touchStart', [(1,width*.6,h*.55),(2,width*.3,h*.55)])
        touch('touchEnd', [])
        page.wait_for_function('() => !document.getElementById("page-gesture")')
        assert page.evaluate('reader.position().start.cfi') == saved
        assert not page.evaluate('messages.some(e=>e.type==="position"&&e.changed)')
    page.wait_for_function('() => reader.layoutReady()')
    assert page.evaluate('document.querySelector("#viewer iframe") === retainedFrame'), 'Resize replaced the publication iframe'
    # Reduced motion / older WebViews preserve direct navigation.
    page.emulate_media(reduced_motion='reduce')
    page.evaluate("reader.turn({delta:1,style:'curl'})")
    assert page.evaluate('document.querySelectorAll("style[data-page-motion]").length') == 0
    page.emulate_media(reduced_motion='no-preference')
    page.evaluate('document.startViewTransition=undefined')
    old = page.evaluate('reader.position().start.cfi')
    page.evaluate("reader.turn({delta:1,style:'curl'})")
    assert page.evaluate('reader.position().start.cfi') != old
    # Neither direct commands nor gestures may construct a sheet beyond the end.
    page.evaluate("""async () => {
      await reader.display('two.xhtml');
      const doc=document.querySelector('#viewer iframe').contentDocument;
      const range=doc.createRange();range.selectNodeContents(doc.body.lastElementChild);range.collapse(false);
      const base=reader.position().start.cfi.slice(8).split('!')[0];
      await reader.display(new ePub.CFI(range,base).toString());
    }""")
    for _ in range(8):
        if page.evaluate('reader.position().atEnd'): break
        page.evaluate('reader.next()')
    assert page.evaluate('reader.position().atEnd'), 'End fixture was not reached: '+json.dumps(page.evaluate('reader.position()'))
    page.evaluate('boundaryStarts=0')
    end_cfi=page.evaluate('reader.position().start.cfi')
    page.evaluate("reader.turn({delta:1,style:'curl'})")
    assert page.evaluate('boundaryStarts') == 0, 'Last page started another animation'
    assert page.evaluate('reader.position().start.cfi') == end_cfi
    compilation = page.evaluate('''async () => {
      const prototype=WebGLRenderingContext.prototype,query=prototype.getProgramParameter;
      let hold=true,done=false,candidate;
      prototype.getProgramParameter=function(program,name){
        if(name===0x91b1&&hold)return false;
        return query.call(this,program,name);
      };
      try{
        candidate=new KMReaderCurlSurface();
        const ready=candidate.whenReady().then(()=>done=true);
        if(candidate.parallelCompilation){
          // Simulate unfinished GPU compilation. Browser tasks must still run
          // and the surface must not report readiness before completion.
          await new Promise(resolve=>setTimeout(resolve,25));
          if(done)throw Error('Curl used an unfinished GPU program');
        }
        hold=false;await ready;
        if(!candidate.initialized)throw Error('GPU initialization did not finish');
        return {parallel:candidate.parallelCompilation};
      }finally{
        prototype.getProgramParameter=query;
        candidate?.gl.getExtension('WEBGL_lose_context')?.loseContext();
      }
    }''')
    print('GPU preparation', json.dumps(compilation))
    assert not errors, errors
    page.evaluate('reader.destroy()')
    assert page.evaluate('document.querySelectorAll("style[data-page-motion],#page-gesture").length') == 0
    browser.close()
print('Visible sheets, localized/bidirectional curl, atomic cancellation, tracked gestures and fallback passed', width)
