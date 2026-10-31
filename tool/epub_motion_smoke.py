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
    page.evaluate('''() => {
      window.motionUpdate = KMReaderSheetEffect.prototype.update;
      window.motionAnimate = KMReaderSheetEffect.prototype.animateTo;
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=async function(move){window.effect=this;return start.call(this,move);};
      KMReaderSheetEffect.prototype.animateTo=function(){return new Promise(()=>{});};
    }''')
    output = Path('artifacts/epub-motion-0.8.4')
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
            assert page.evaluate('effect.svg.querySelector("feImage").getAttribute("href").startsWith("data:image/png")')
        assert page.evaluate('document.querySelectorAll("style[data-page-motion]").length') == 1
        page.evaluate('effect.stop()')
    page.evaluate('() => { KMReaderSheetEffect.prototype.animateTo=motionAnimate; }')
    # Actual automatic effects remain visible mid-flight, not just a retained
    # JS object after Chromium already removed its snapshot pseudo-elements.
    page.evaluate("reader.turn({delta:1,style:'slide'})")
    page.wait_for_timeout(100)
    assert page.evaluate("document.getAnimations().some(a=>a.effect?.pseudoElement?.startsWith('::view-transition-'))"), 'Automatic effect vanished too early'
    assert page.evaluate('effect.progress') > 0
    page.wait_for_function('() => !document.querySelector("style[data-page-motion]")')
    # Use real pointer capture across iframe/top-document boundaries.
    saved = page.evaluate('reader.position().start.cfi')
    saved_page = page.evaluate('reader.position().start.displayed.page')
    page.evaluate('messages.length=0')
    page.mouse.move(xcoord(width - 6), height * .55)
    page.mouse.down()
    page.mouse.move(xcoord(width * .55), height * .55, steps=12)
    page.wait_for_function('() => document.getElementById("page-gesture") && window.effect && !effect.stopped')
    page.wait_for_timeout(100)
    progress = page.evaluate('effect.progress')
    assert .30 < progress < .55, progress
    assert not page.evaluate('messages.some(e=>e.type==="position"&&e.changed)'), 'Gesture preview wrote progress'
    page.mouse.move(xcoord(width * .35), height * .52, steps=4)
    assert page.evaluate('effect.progress') > progress
    page.mouse.up()
    page.wait_for_function('() => !document.getElementById("page-gesture")')
    assert page.evaluate('reader.position().start.cfi') != saved
    assert page.evaluate('reader.position().start.displayed.page') > saved_page
    assert page.evaluate('messages.filter(e=>e.type==="position"&&e.changed).length') == 1
    saved = page.evaluate('reader.position().start.cfi')
    page.evaluate('messages.length=0')
    page.mouse.move(xcoord(width - 6), height * .55)
    page.mouse.down()
    page.mouse.move(xcoord(width * .84), height * .55, steps=7)
    page.wait_for_timeout(100)
    page.mouse.move(xcoord(width * .97), height * .55, steps=6)
    page.mouse.up()
    page.wait_for_function('() => !document.getElementById("page-gesture")')
    assert page.evaluate('reader.position().start.cfi') == saved, 'Canceled drag changed CFI'
    assert not page.evaluate('messages.some(e=>e.type==="position"&&e.changed)'), 'Canceled drag wrote progress'
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
print('Visible slide/cover/cylindrical curl, tracked/canceled gestures, resize and fallback passed', width)
