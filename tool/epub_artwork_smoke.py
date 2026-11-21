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
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=function(...args){
        window.captureArtwork=this.capture;
        return start.apply(this,args);
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
        texture = page.evaluate('''async () => {
          const image=await captureArtwork(), canvas=document.createElement('canvas');
          canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;
          canvas.getContext('2d').drawImage(image,0,0);
          return canvas.toDataURL('image/png').split(',')[1];
        }''')
        snapshot = Image.open(io.BytesIO(base64.b64decode(texture)))
        assert snapshot.size == live.size, (snapshot.size, live.size)
        live_bounds, texture_bounds = bounds(live, color), bounds(snapshot, color)
        assert live_bounds and texture_bounds, (name, live_bounds, texture_bounds)
        assert max(abs(a - b) for a, b in zip(live_bounds, texture_bounds)) <= 2, (
            name, live_bounds, texture_bounds)
        measured.append((name, live_bounds, texture_bounds))
    assert measured[0] == measured[2], measured
    print(json.dumps(measured))
