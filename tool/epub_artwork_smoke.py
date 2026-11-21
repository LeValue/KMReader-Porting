"""Compare HTML and SVG artwork in live pages and in the curl textures."""

import base64
import io
import json
import sys

from PIL import Image
from playwright.sync_api import sync_playwright


def bounds(image, color):
    mask = Image.new('1', image.size)
    mask.putdata([max(abs(a - b) for a, b in zip(pixel, color)) < 30
                  for pixel in image.convert('RGB').get_flattened_data()])
    return mask.getbbox()


url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width': 430, 'height': 640}, device_scale_factor=2)
    page.goto(url)
    page.evaluate('''() => {
      const render=ePub.Book.prototype.renderTo,start=KMReaderSheetEffect.prototype.start;
      ePub.Book.prototype.renderTo=function(...args){return window.artworkRendition=render.apply(this,args);};
      window.artworkScroll=()=>artworkRendition.manager.container.scrollLeft;
      KMReaderSheetEffect.prototype.start=function(...args){
        window.captureArtwork=this.capture;
        window.artworkPreview=args[1]?.after;
        return start.apply(this,args);
      };
      window.encodeArtwork=image=>{
        const canvas=document.createElement('canvas');
        canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;
        canvas.getContext('2d').drawImage(image,0,0);
        return canvas.toDataURL('image/png').split(',')[1];
      };
    }''')
    page.evaluate('config => reader.open(config)', config)
    page.evaluate("reader.turn({delta:1,style:'curl'})")
    page.evaluate('reader.suspendInput(true)')
    page.evaluate("reader.display('one.xhtml',false)")

    measured = []
    for name, color in [('picture', (199, 0, 176)), ('svg', (0, 110, 210)),
                        ('picture', (199, 0, 176))]:
        if measured:
            page.evaluate('reader.next()' if len(measured) == 1 else 'reader.previous()')
        page.evaluate('reader.whenIdle()')
        live = Image.open(io.BytesIO(page.screenshot()))
        texture = page.evaluate('async () => encodeArtwork(await captureArtwork())')
        snapshot = Image.open(io.BytesIO(base64.b64decode(texture)))
        assert snapshot.size == live.size, (snapshot.size, live.size)
        live_bounds, texture_bounds = bounds(live, color), bounds(snapshot, color)
        assert live_bounds and texture_bounds, (name, live_bounds, texture_bounds)
        assert max(abs(a - b) for a, b in zip(live_bounds, texture_bounds)) <= 2, (
            name, live_bounds, texture_bounds)
        measured.append((name, live_bounds, texture_bounds))
    assert measured[0] == measured[2], measured
    page.evaluate('reader.suspendInput(false)')
    for chapter, start, end, color in [(None, 426, 140, (0, 110, 210)),
                                      (None, 4, 290, (199, 0, 176)),
                                      ('two.xhtml', 4, 290, (199, 0, 176))]:
        if chapter:
            page.evaluate('chapter => reader.display(chapter, false)', chapter)
            page.evaluate('reader.whenIdle()')
        page.evaluate('window.artworkPreview=null')
        saved = page.evaluate('[reader.position().start.href, artworkScroll()]')
        page.mouse.move(start, 340)
        page.mouse.down()
        page.mouse.move(end, 340, steps=12)
        page.wait_for_function('() => window.artworkPreview && document.getElementById("page-gesture")')
        assert page.evaluate('[reader.position().start.href, artworkScroll()]') == saved, 'The drag moved the live page before release'
        texture = page.evaluate('encodeArtwork(artworkPreview)')
        during = Image.open(io.BytesIO(base64.b64decode(texture)))
        page.mouse.up()
        page.wait_for_function('() => !document.getElementById("page-gesture")')
        page.evaluate('reader.whenIdle()')
        destination = page.evaluate('[reader.position().start.href, artworkScroll()]')
        assert destination != saved, 'The mouse drag did not move the page'
        if chapter:
            assert destination[0] == 'one.xhtml', destination
        live = Image.open(io.BytesIO(page.screenshot()))
        actual, preview = bounds(live, color), bounds(during, color)
        assert actual and preview, (actual, preview)
        assert max(abs(a - b) for a, b in zip(actual, preview)) <= 2, (actual, preview)
        measured.append(('mouse drag', actual, preview))
    print(json.dumps(measured))
