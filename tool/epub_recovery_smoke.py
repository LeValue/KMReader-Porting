#!/usr/bin/env python3
"""Fault injection for animation cleanup, readable pixels and saved-CFI reopen."""
import io
import json
import sys

from PIL import Image
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport=config['viewport'])
    page.set_default_timeout(10000)
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.goto(url)
    page.evaluate('(c)=>reader.open(c)', config)
    page.evaluate('''() => {
      window.effects=[];
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=function(...args){effects.push(this);return start.apply(this,args);};
    }''')
    first = page.evaluate('reader.position().start.cfi')
    page.evaluate('''async () => {
      const render=KMReaderCurlSurface.prototype.render;
      KMReaderCurlSurface.prototype.render=function(p,...args){
        if(p>0&&p<1)throw Error('Injected GPU draw failure');
        return render.call(this,p,...args);
      };
      try{
        await reader.turn({delta:1,style:'curl'});
        const effect=effects.at(-1);
        if(!effect?.surface)throw Error('Fixture did not start a GPU animation');
        await Promise.race([
          new Promise(resolve=>{const poll=()=>effect.stopped?resolve():setTimeout(poll,10);poll();}),
          new Promise((_,reject)=>setTimeout(()=>reject(Error('Failed frame left an opaque animation over the book')),2000))
        ]);
      }finally{KMReaderCurlSurface.prototype.render=render;}
    }''')
    assert page.evaluate('reader.position().start.cfi') != first, 'Failed cosmetic draw lost navigation'

    def readable():
        page.evaluate('reader.whenIdle()')
        assert page.evaluate('document.querySelectorAll("#page-curl-surface,style[data-page-motion],#page-gesture").length') == 0
        # Check delivered pixels rather than accepting a DOM position alone.
        image = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        width, height = image.size
        crop = image.crop((width//4, height//4, width*3//4, height*3//4))
        colors = crop.getcolors(crop.width * crop.height)
        assert sum(n for n, p in colors if max(p) < 120) > 150, 'Text is invisible after recovery'
        assert sum(n for n, p in colors if min(p) > 180) > 150, 'Missing texture was mistaken for text'

    readable()
    # A failed surface is retired for this reader, so idle warming / another
    # input cannot repeatedly create the same broken graphics context.
    count = page.evaluate('effects.length')
    saved = page.evaluate('reader.position().start.cfi')
    page.evaluate("reader.turn({delta:1,style:'curl'})")
    assert page.evaluate('effects.length') == count
    assert page.evaluate('reader.position().start.cfi') != saved
    readable()
    saved = page.evaluate('reader.position().start.cfi')
    page.reload()
    page.evaluate('(c)=>reader.open(c)', {**config, 'cfi': saved})
    assert page.evaluate('reader.position().start.cfi') == saved
    readable()

    # Use tiny deterministic snapshots for driver/lifecycle faults, while the
    # real EPUB underneath still has to navigate and deliver readable pixels.
    def fresh(**overrides):
        page.reload()
        page.evaluate('(c)=>reader.open(c)', {**config, 'cfi': saved, **overrides})
        page.evaluate('''async () => {
          const canvas=document.createElement('canvas');canvas.width=64;canvas.height=64;
          canvas.getContext('2d').fillRect(0,0,64,64);
          window.snapshot=new Image();snapshot.src=canvas.toDataURL();await snapshot.decode();
          window.faultEffect=new KMReaderSheetEffect('curl',1,{},.5,false,false,async()=>snapshot);
          window.untilStopped=effect=>Promise.race([
            new Promise(resolve=>{const poll=()=>effect.stopped?resolve():setTimeout(poll,10);poll();}),
            new Promise((_,reject)=>setTimeout(()=>reject(Error('Animation never retired')),4000))
          ]);
        }''')

    fresh()
    page.evaluate('''async () => {
      if(!await faultEffect.start(()=>reader.next()))throw Error('GPU did not start');
      faultEffect.surface.render=()=>{throw Error('Injected pointer draw failure');};
      faultEffect.track(.4,{x:150,y:300});await untilStopped(faultEffect);
      await faultEffect.animateTo(1,200);
    }''')
    readable()

    fresh()
    page.evaluate('''async () => {
      if(!await faultEffect.start(()=>reader.next()))throw Error('GPU did not start');
      const extension=faultEffect.surface.gl.getExtension('WEBGL_lose_context');
      if(!extension)throw Error('Context-loss test unavailable');
      const flight=faultEffect.animateTo(1,900);
      extension.loseContext();await untilStopped(faultEffect);await flight;
      if(KMReaderSheetEffect.supported('curl'))throw Error('Failed GPU context was reused');
    }''')
    readable()

    fresh()
    pending = page.evaluate('''async () => {
      const prototype=WebGLRenderingContext.prototype,query=prototype.getProgramParameter;
      prototype.getProgramParameter=function(p,name){return name===0x91b1?false:query.call(this,p,name);};
      try{
        const start=performance.now();
        const animated=await faultEffect.start(()=>reader.next());
        if(faultEffect.surface.parallelCompilation&&animated)throw Error('Used incomplete shaders');
        faultEffect.stop();
        if(performance.now()-start>3500)throw Error('GPU preparation was unbounded');
        return faultEffect.surface.parallelCompilation;
      }finally{prototype.getProgramParameter=query;}
    }''')
    assert page.evaluate('reader.position().start.cfi') != saved, 'GPU timeout swallowed the requested turn'
    readable()

    fresh()
    page.evaluate('''async () => {
      let captures=0;
      faultEffect.capture=()=>++captures===1?Promise.resolve(snapshot):new Promise(()=>{});
      if(await faultEffect.start(()=>reader.next()))throw Error('Used unfinished page capture');
      if(!faultEffect.stopped)throw Error('Stalled capture retained an opaque canvas');
    }''')
    readable()

    fresh()
    page.evaluate('''async () => {
      faultEffect.capture=()=>new Promise(()=>{});
      let moves=0;const start=faultEffect.start(async()=>moves++);
      faultEffect.stop();await start;
      if(moves||KMReaderCurlSurface.disabled)throw Error('Cancelled capture advanced or disabled a healthy driver');
    }''')
    readable()

    fresh()
    page.evaluate('''async () => {
      if(!await faultEffect.start(()=>reader.next()))throw Error('GPU did not start');
      const raf=window.requestAnimationFrame;window.requestAnimationFrame=()=>0;
      try{await faultEffect.animateTo(1,100);if(!faultEffect.stopped)throw Error('Suspended RAF retained the canvas');}
      finally{window.requestAnimationFrame=raf;}
    }''')
    readable()

    fresh()
    page.evaluate('''async () => {
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=function(...args){window.liveEffect=this;return start.apply(this,args);};
      try{
        await reader.turn({delta:1,style:'curl'});
        window.dispatchEvent(new Event('pagehide'));
        if(!liveEffect.stopped)throw Error('Backgrounding retained an opaque animation');
      }finally{KMReaderSheetEffect.prototype.start=start;}
    }''')
    readable()

    for style in ['slide', 'cover']:
        fresh()
        page.evaluate('''async style => {
          await reader.next();
          const effect=new KMReaderSheetEffect(style,1,{});
          if(!await effect.start(async()=>{}))throw Error('Compositor did not start');
          // A thrown final style update must settle the flight and retire the
          // browser snapshots just like a failed GPU frame.
          effect.update=()=>{throw Error('Injected compositor style failure');};
          await effect.animateTo(1,80);
          if(!effect.stopped||!effect.failed)throw Error('Failed compositor was not retired');
        }''', style)
        readable()
        fresh()
        page.evaluate('''async style => {
          await reader.next();
          const effect=new KMReaderSheetEffect(style,1,{});
          if(!await effect.start(async()=>{}))throw Error('Compositor did not start');
          const flight=effect.animateTo(1,300);
          if(!effect.compositor)throw Error('Compositor cancellation probe unavailable');
          effect.compositor.animations[0].cancel();await flight;
          if(!effect.stopped)throw Error('Rejected compositor retained its snapshots');
        }''', style)
        readable()

    fresh()
    page.evaluate('''async () => {
      const start=document.startViewTransition;let moves=0;
      document.startViewTransition=move=>({ready:new Promise(()=>{}),finished:new Promise(()=>{}),
        updateCallbackDone:Promise.resolve().then(move),skipTransition(){}});
      try{
        const effect=new KMReaderSheetEffect('slide',1,{});
        const animated=await effect.start(async()=>{moves++;await reader.next();});
        if(animated||!effect.stopped||moves!==1)throw Error('Stalled transition duplicated or blocked navigation');
      }finally{document.startViewTransition=start;}
    }''')
    readable()

    fresh(disableMotion=True, preferences={**config['preferences'], 'transition': 'curl'})
    page.evaluate('''async () => {
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=()=>{throw Error('Recovered renderer attempted graphics again');};
      try{
        for(const style of ['curl','slide','cover'])await reader.turn({delta:1,style});
        await reader.preferences({...''' + json.dumps(config['preferences']) + ''',transition:'curl'});
        await new Promise(resolve=>setTimeout(resolve,400));
        if(KMReaderCurlSurface.shared)throw Error('Recovered renderer warmed GPU resources');
      }finally{KMReaderSheetEffect.prototype.start=start;}
    }''')
    readable()
    fresh()
    page.evaluate('''async () => {
      const display=ePub.Rendition.prototype.display;
      ePub.Rendition.prototype.display=function(...args){window.boundsRendition=this;return display.apply(this,args);};
      try{await reader.display(reader.position().start.cfi);}finally{ePub.Rendition.prototype.display=display;}
      window.collapsePublication=()=>boundsRendition.manager.views.forEach(view=>{
        if(view.displayed&&view.iframe){view.lockedHeight=0;view.reframe(view.width(),0);}
      });
      collapsePublication();
      if(reader.layoutReady())throw Error('Collapsed iframe was reported as a readable publication');
      await reader.whenIdle();
      if(!reader.layoutReady()||document.querySelector('#viewer iframe').clientHeight===0)throw Error('Idle reader did not repair collapsed publication bounds');
    }''')
    readable()
    page.evaluate('''async () => {
      const cfi=reader.position().start.cfi;collapsePublication();await reader.display(cfi);
      if(document.querySelector('#viewer iframe').clientHeight===0)throw Error('Saved-CFI display kept a collapsed iframe');
      if(reader.position().start.cfi!==cfi)throw Error('Dimension repair changed the reading locator');
    }''')
    readable()
    page.evaluate('''async () => {
      const raf=window.requestAnimationFrame;
      try{
        for(const offset of [-1000,0,1000]){
          let time=performance.now()+offset,callbacks=0;
          const samples=[],effect=new KMReaderSheetEffect('curl',1,{});
          window.requestAnimationFrame=callback=>setTimeout(()=>{callbacks++;callback(time+=120);},0);
          effect.update=value=>{effect.progress=value;samples.push(value);};
          try{
            await effect.animateTo(1,380,{automatic:true});
            if(effect.progress!==1||callbacks>5)throw Error('Slow frames stretched the requested animation duration');
            if(samples[0]!==0||!samples.some(p=>p>0&&p<1))throw Error('Delayed frame delivery swallowed the animation');
          }finally{effect.stop();}
        }
      }finally{window.requestAnimationFrame=raf;}
    }''')
    page.evaluate('''() => {
      const surface=KMReaderCurlSurface.shared;reader.destroy();
      if(surface&&(!surface.disposed||!surface.gl.isContextLost()))throw Error('Closed reader retained its GPU allocations');
    }''')
    assert not errors, errors
    browser.close()
print('Draw/pointer faults, context loss, compile/capture deadlines, cancellation, suspended frames, backgrounding, readable pixels and saved-CFI reopen passed; parallel compile:', pending)
