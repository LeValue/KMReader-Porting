#!/usr/bin/env python3
"""Stress the shipped EPUB engine; timings are command latency, not native FPS."""
import io
import json
import statistics
import sys

from PIL import Image
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport=config['viewport'])
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.add_init_script("window.messages=[];addEventListener('readerEvent',e=>messages.push(e.detail));")
    page.goto(url)
    page.evaluate('''() => {
      const render = ePub.Book.prototype.renderTo;
      ePub.Book.prototype.renderTo = function(...args) {
        return window.renditionFixture = render.apply(this, args);
      };
    }''')
    page.evaluate('(config)=>reader.open(config)', config)
    assert page.evaluate("messages.some(e=>e.type==='ready')")
    cdp = page.context.new_cdp_session(page)
    cdp.send('Performance.enable')

    def heap():
        cdp.send('HeapProfiler.collectGarbage')
        return next(m['value'] for m in cdp.send('Performance.getMetrics')['metrics'] if m['name'] == 'JSHeapUsedSize')

    # Keep just a count, not unbounded copies of all position messages.
    page.evaluate('messages.length=0')
    heap_before = heap()
    result = page.evaluate('''async () => {
      const viewer=document.getElementById('viewer'), animate=KMReaderSheetEffect.prototype.animateTo;
      let animations=0, maxActive=0;
      KMReaderSheetEffect.prototype.animateTo=function(){
        animations++;
        maxActive=Math.max(maxActive,document.querySelectorAll('style[data-page-motion]').length);
        return new Promise(()=>{});
      };
      const times=[], positions=new Set([reader.position().start.cfi]);
      for(let i=0;i<48;i++) {
        const before=reader.position().start.cfi, start=performance.now();
        await Promise.race([
          reader.turn({delta:1,style:['slide','cover','curl','none'][i%4]}),
          new Promise((_,reject)=>setTimeout(()=>reject(Error('Animation blocked navigation')),2000))
        ]);
        times.push(performance.now()-start);
        const after=reader.position().start.cfi;
        if(before===after || positions.has(after)) throw Error('Repeated locator '+i);
        positions.add(after);
        if(document.querySelector('#page-transition')) throw Error('Snapshot overlay retained');
      }
      KMReaderSheetEffect.prototype.animateTo=animate;
      // Mutations arrive concurrently, including a resize while reflow is queued.
      const preferences={...CONFIG.preferences,fontSize:26};
      const a=reader.turn({delta:1,style:'slide'});
      const b=reader.preferences(preferences);
      dispatchEvent(new Event('resize'));
      const c=reader.turn({delta:1,style:'slide'});
      await Promise.all([a,b,c]);
      await reader.preferences(CONFIG.preferences);
      await new Promise(resolve=>setTimeout(resolve,200));
      return {times,positions:positions.size,animations,maxActive,
        active:document.querySelectorAll('style[data-page-motion]').length,transform:getComputedStyle(viewer).transform,
        iframes:document.querySelectorAll('iframe').length,
        text:renditionFixture.getContents().some(c=>c.document.body.textContent.trim().length>100)};
    }'''.replace('CONFIG', json.dumps(config)))
    assert result['positions'] == 49, result
    assert result['animations'] == 36 and result['maxActive'] <= 1, result
    assert result['active'] == 0 and result['transform'] == 'none', result
    assert result['text'] and result['iframes'] <= 3, result
    # Pixel evidence catches a transformed/clipped/transparent live viewport.
    image = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
    width, height = image.size
    pixels = image.crop((width//4, height//4, width*3//4, height*3//4)).getdata()
    assert sum(max(pixel) < 120 for pixel in pixels) > 150, 'Blank reader pixels'
    page.emulate_media(reduced_motion='reduce')
    page.evaluate("reader.turn({delta:1,style:'slide'})")
    assert page.evaluate("document.getElementById('viewer').getAnimations().length") == 0
    page.evaluate('messages.length=0')
    heap_after = heap()
    # Coarse runaway guard, after collecting unreachable documents/animations.
    assert heap_after - heap_before < 16 * 1024 * 1024, (heap_before, heap_after)
    assert not errors, errors
    print(json.dumps({'viewport': config['viewport'],
        'turn_median_ms': round(statistics.median(result['times']), 2),
        'turn_max_ms': round(max(result['times']), 2),
        'heap_before': heap_before, 'heap_after': heap_after,
        'unique_positions': result['positions'], 'max_active_animations': result['maxActive']}))
    page.evaluate('reader.destroy()')
    browser.close()
