#!/usr/bin/env python3
"""Compare compact curl textures against the full publication raster, pixel by pixel."""
import base64
import io
import json
import sys

from PIL import Image, ImageChops
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport=config['viewport'])
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.goto(url)
    page.evaluate('''() => {
      const render=ePub.Book.prototype.renderTo,start=KMReaderSheetEffect.prototype.start;
      ePub.Book.prototype.renderTo=function(...args){return window.snapshotRendition=render.apply(this,args);};
      KMReaderSheetEffect.prototype.start=function(...args){window.pageCapture=this.capture;return start.apply(this,args);};
      window.compactSnapshot=KMReaderPageSnapshot.compact;
    }''')
    preferences = {**config['preferences'], 'transition': 'curl'}
    page.evaluate('(c)=>reader.open(c)', {**config, 'preferences': preferences})
    page.evaluate("reader.turn({delta:1,style:'curl'})")
    page.evaluate('reader.suspendInput(true)')
    for fraction in [0, .02, .5, .99]:
        result = page.evaluate('''async ({preferences,fraction}) => {
          const content=snapshotRendition.getContents()[0],doc=content.document;
          const paragraphs=doc.querySelectorAll('p'),range=doc.createRange();
          range.selectNodeContents(paragraphs[Math.floor((paragraphs.length-1)*fraction)]);range.collapse(true);
          await reader.display(content.cfiFromRange(range));
          const encode=image=>{
            const canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;
            canvas.getContext('2d').drawImage(image,0,0);return canvas.toDataURL('image/png').split(',')[1];
          };
          KMReaderPageSnapshot.compact=()=>{};
          await reader.preferences({...preferences,tapScroll:81});
          const original=encode(await pageCapture());
          let glyphsBefore=0,glyphsAfter=0;
          KMReaderPageSnapshot.compact=(root,...args)=>{
            glyphsBefore=root.querySelector('body').textContent.length;
            compactSnapshot(root,...args);glyphsAfter=root.querySelector('body').textContent.length;
          };
          await reader.preferences({...preferences,tapScroll:82});
          const optimized=encode(await pageCapture());
          return {original,optimized,glyphsBefore,glyphsAfter};
        }''', {'preferences': preferences, 'fraction': fraction})
        original, optimized = [Image.open(io.BytesIO(base64.b64decode(result[k]))).convert('RGB')
                               for k in ['original', 'optimized']]
        changed = sum(max(pixel) > 4 for pixel in ImageChops.difference(original, optimized).getdata())
        assert changed == 0, (fraction, config['viewport'], config['direction'], changed)
        assert result['glyphsAfter'] < result['glyphsBefore'] / 3, result['glyphsAfter']
    # Changing reading mode releases curl's retained GPU and image allocations.
    page.evaluate('(p)=>reader.preferences({...p,flow:"scrolled"})', preferences)
    assert page.evaluate('KMReaderCurlSurface.shared == null'), 'Vertical reading retained the curl GPU context'
    page.evaluate('reader.destroy()')
    assert not errors, errors
    browser.close()
print('Four compact/full page rasters match; offscreen glyphs and inactive curl resources released', config['viewport'], config['direction'])
