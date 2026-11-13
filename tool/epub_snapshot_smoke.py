#!/usr/bin/env python3
"""Compare compact curl textures against the full publication raster, pixel by pixel."""
import base64
import io
import json
import sys

from PIL import Image, ImageChops, ImageStat
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport=config['viewport'], device_scale_factor=config.get('deviceScaleFactor',1),
        is_mobile=config.get('deviceScaleFactor',1)>1,has_touch=True)
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
        live = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        assert max(ImageStat.Stat(ImageChops.difference(live, optimized)).mean) < 1, (
            'Curl changed the live text layout', fraction, config['viewport'])
        assert result['glyphsAfter'] < result['glyphsBefore'] / 3, result['glyphsAfter']
    if config.get('deviceScaleFactor',1)>1:
        live=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        page.evaluate('''async () => {
          window.nativeTexture=await pageCapture();
          window.nativeSurface=new KMReaderCurlSurface();
          await nativeSurface.whenReady();
          nativeSurface.upload(nativeTexture,nativeTexture,innerWidth,innerHeight);
          document.body.append(nativeSurface.canvas);
        }''')
        for endpoint in [0, .00001, .99999, 1]:
            page.evaluate('(p)=>nativeSurface.render(p,false,1,0,.5)',endpoint)
            animated=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
            assert animated.size==live.size
            difference=max(ImageStat.Stat(ImageChops.difference(live,animated)).mean)
            assert difference<1, ('Near-flat curl changed native glyphs',endpoint,difference)
        page.evaluate('()=>{nativeSurface.dispose();}')
    if config['direction'] == 'ltr' and config['viewport']['width'] == 390:
        note = page.evaluate('''async () => {
          const content=snapshotRendition.getContents()[0],doc=content.document,pre=doc.querySelector('pre');
          const range=doc.createRange();range.selectNodeContents(pre);range.collapse(true);
          await reader.display(content.cfiFromRange(range));
          const style=doc.defaultView.getComputedStyle(pre),text=pre.firstChild;
          const column=snapshotRendition.manager.layout.columnWidth;
          let widest=0;
          for(const match of text.textContent.matchAll(/\\S+/g)){
            range.setStart(text,match.index);range.setEnd(text,match.index+match[0].length);
            for(const rect of range.getClientRects())widest=Math.max(widest,rect.width);
          }
          // Re-wrapping the note keeps every authored word and line break.
          return {whiteSpace:style.whiteSpace,width:pre.clientWidth,overflow:pre.scrollWidth,widest,column,
            lines:text.textContent.split('\\n').length,words:text.textContent.match(/\\S+/g).length};
        }''')
        assert note['whiteSpace'] == 'pre-wrap', note
        assert note['overflow'] <= note['width'] + 1, note
        assert note['widest'] < note['column'] and note['lines'] == 24, note
        assert note['words'] == 24 * 18, note
        overflow = page.evaluate('''async () => {
          await reader.display('one.xhtml');
          const doc=snapshotRendition.getContents()[0].document,p=doc.querySelector('p');
          p.style.whiteSpace='nowrap';p.textContent+=' Overflowing authored text must remain visible. '.repeat(50);
          await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
          snapshotRendition.manager.scrollTo(innerWidth,0,true);
          await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
          const encode=image=>{
            const canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;
            canvas.getContext('2d').drawImage(image,0,0);return canvas.toDataURL('image/png').split(',')[1];
          };
          KMReaderPageSnapshot.compact=()=>{};doc.body.dataset.snapshotTest='full';await Promise.resolve();
          const original=encode(await pageCapture());
          KMReaderPageSnapshot.compact=compactSnapshot;doc.body.dataset.snapshotTest='compact';await Promise.resolve();
          return {original,optimized:encode(await pageCapture())};
        }''')
        original, optimized = [Image.open(io.BytesIO(base64.b64decode(overflow[k]))).convert('RGB')
                               for k in ['original', 'optimized']]
        assert not ImageChops.difference(original, optimized).getbbox(), 'Snapshot hid authored text overflowing into the next page'
    # Changing reading mode releases curl's retained GPU and image allocations.
    page.evaluate('(p)=>reader.preferences({...p,flow:"scrolled"})', preferences)
    assert page.evaluate('KMReaderCurlSurface.shared == null'), 'Vertical reading retained the curl GPU context'
    page.evaluate('reader.destroy()')
    assert not errors, errors
    browser.close()
print('Four compact/full page rasters match; offscreen glyphs and inactive curl resources released', config['viewport'], config['direction'])
