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
    output = Path('artifacts/epub-motion-0.8.5')
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
            # A moving black page gains a visible gray paper background.
            assert sum(15 < min(p) and max(p) < 80 for p in pixels) > width * height * .05, style
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
    page.evaluate('() => { KMReaderSheetEffect.prototype.animateTo=motionAnimate; }')
    # Actual automatic effects remain visible mid-flight, not just a retained
    # JS object after Chromium already removed its snapshot pseudo-elements.
    page.evaluate("reader.turn({delta:1,style:'slide'})")
    page.wait_for_timeout(100)
    assert page.evaluate("document.getAnimations().some(a=>a.effect?.pseudoElement?.startsWith('::view-transition-'))"), 'Automatic effect vanished too early'
    assert page.evaluate('effect.progress') > 0
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
    assert not errors, errors
    page.evaluate('reader.destroy()')
    assert page.evaluate('document.querySelectorAll("style[data-page-motion],#page-gesture").length') == 0
    browser.close()
print('Visible sheets, localized/bidirectional curl, atomic cancellation, tracked gestures and fallback passed', width)
