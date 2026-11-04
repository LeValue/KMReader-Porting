#!/usr/bin/env python3
"""Cold-page readiness, snapshot identities and navigation-free curl previews."""
import io
import json
import sys
from pathlib import Path
from PIL import Image, ImageChops, ImageStat
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
width, height = config['viewport']['width'], config['viewport']['height']
rtl = config.get('direction') == 'rtl'
xcoord = lambda x: width - x if rtl else x
with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport=config['viewport'])
    page.set_default_timeout(10000)
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.goto(url)
    page.evaluate("""() => {
      window.warms=0;window.work={serialize:0,decode:0,upload:0};
      for(const [prototype,name,key] of [[XMLSerializer.prototype,'serializeToString','serialize'],
          [HTMLImageElement.prototype,'decode','decode'],[WebGLRenderingContext.prototype,'texImage2D','upload']]){
        const original=prototype[name];prototype[name]=function(...args){work[key]++;return original.apply(this,args);};
      }
      const render=KMReaderCurlSurface.prototype.render;
      KMReaderCurlSurface.prototype.render=function(p,...args){
        const result=render.call(this,p,...args);
        if(!this.effect&&p===0)warms++;
        return result;
      };
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=function(move,preview){
        window.effect=this;window.previewPair=preview;
        return start.call(this,move,preview);
      };
    }""")
    config['preferences'] = {**config['preferences'], 'transition':'curl', 'flow':'paged'}
    page.evaluate('(p)=>window.testPreferences=p', config['preferences'])
    page.evaluate('(c)=>reader.open(c)', config)
    last_warm = 0
    for turn in range(4):
        page.wait_for_function('(n)=>warms>n', arg=last_warm)
        before = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        saved = page.evaluate('reader.position().start.cfi')
        page.evaluate('window.retainedFrame=document.querySelector("#viewer iframe");window.beforeWork={...work}')
        page.mouse.move(xcoord(width - 6), height * .55)
        page.mouse.down()
        page.mouse.move(xcoord(width * .65), height * .55, steps=7)
        page.wait_for_function('() => window.effect && !effect.stopped && effect.progress>.1')
        assert page.evaluate('!!previewPair'), 'First drag did not reuse an idle page pair'
        assert page.evaluate('JSON.stringify(work)===JSON.stringify(beforeWork)'), ('First drag did snapshot/texture work',page.evaluate('({work,beforeWork})'))
        assert page.evaluate('reader.position().start.cfi') == saved, 'Preview changed the CFI'
        page.evaluate('effect.update(0)')
        flat = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        assert max(ImageStat.Stat(ImageChops.difference(before,flat)).mean)<6, 'Fold front is not the current page'
        if turn % 2 == 0:
            # Cancel, retry on the same page, then commit. Neither cancellation
            # nor the next page may depend on a previous gesture warming it.
            page.mouse.move(xcoord(width * .98), height * .55, steps=5)
            page.mouse.up()
            page.wait_for_function('() => !document.getElementById("page-gesture")')
            assert page.evaluate('reader.position().start.cfi') == saved
            assert page.evaluate('document.querySelector("#viewer iframe")===retainedFrame')
            page.wait_for_function('(n)=>warms>n', arg=page.evaluate('warms')-1)
            page.mouse.move(xcoord(width - 6), height * .55)
            page.mouse.down()
            page.mouse.move(xcoord(width * .55), height * .55, steps=8)
            page.wait_for_function('() => window.effect && !effect.stopped && effect.progress>.1')
        page.evaluate('effect.update(1)')
        target = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        page.mouse.move(xcoord(width * .3), height * .55, steps=3)
        last_warm = page.evaluate('warms')
        page.mouse.up()
        page.wait_for_function('() => !document.getElementById("page-gesture")')
        assert page.evaluate('reader.position().start.cfi') != saved
        live = Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        assert max(ImageStat.Stat(ImageChops.difference(target,live)).mean)<6, 'Page under the fold is not the destination'
    # Window focus loss must retire a held gesture without waiting for a
    # pointerup that the app will never receive.
    page.wait_for_function('(n)=>warms>n', arg=last_warm)
    saved = page.evaluate('reader.position().start.cfi')
    page.mouse.move(xcoord(width - 6), height * .55)
    page.mouse.down()
    page.mouse.move(xcoord(width * .65), height * .55, steps=7)
    page.wait_for_function('() => window.effect && !effect.stopped && effect.progress>.1')
    page.evaluate('window.dispatchEvent(new Event("blur"))')
    page.mouse.up()
    page.wait_for_function('() => !document.getElementById("page-gesture")')
    assert page.evaluate('reader.position().start.cfi') == saved
    page.evaluate('reader.next()')
    assert page.evaluate('reader.position().start.cfi') != saved, 'Focus loss locked the navigation queue'
    front_shade=page.evaluate("""async () => {
      const probe=async surface=>{
      const g=surface.gl;await surface.whenReady();
      const stock=document.createElement('canvas');stock.width=innerWidth;stock.height=innerHeight;
      const c=stock.getContext('2d');c.fillStyle='#efe5d0';c.fillRect(0,0,stock.width,stock.height);
      surface.upload(stock,stock,innerWidth,innerHeight);
      const samples=[];
      for(const p of [.2,.35,.5]){
        surface.render(p,false,1,0,.5);
        g.clear(g.DEPTH_BUFFER_BIT);g.enable(g.DEPTH_TEST);g.enable(g.CULL_FACE);g.cullFace(g.BACK);
        const program=surface.sheet;g.useProgram(program.p);
        g.bindBuffer(g.ARRAY_BUFFER,surface.mesh);g.vertexAttribPointer(program.a,2,g.FLOAT,false,0,0);
        g.enableVertexAttribArray(program.a);g.bindBuffer(g.ELEMENT_ARRAY_BUFFER,surface.indices);
        g.drawElements(g.TRIANGLES,surface.count,g.UNSIGNED_SHORT,0);
        const w=innerWidth,wave=Math.sin(Math.PI*p),r=w*.075*wave,alpha=.75*wave;
        const f=w*(1-p)-r*(Math.PI-alpha)*.5,reach=Math.min(f,w*.18),start=f-reach;
        const row=[];
        for(let i=0;i<=20;i++){
          const theta=alpha*i/20,x=start+reach/alpha*Math.sin(theta),z=2*reach/alpha*Math.sin(theta/2)**2;
          const screen=x*w*3/(w*3-z),pixel=new Uint8Array(4);
          g.readPixels(Math.round(screen*surface.canvas.width/innerWidth),Math.floor(surface.canvas.height/2),1,1,g.RGBA,g.UNSIGNED_BYTE,pixel);
          row.push(pixel[0]);
        }
        g.disable(g.CULL_FACE);g.disable(g.DEPTH_TEST);samples.push({p,row});
      }
      return samples;};
      const current=await probe(KMReaderCurlSurface.shared);
      const shader=WebGLRenderingContext.prototype.shaderSource;let regression;
      try {
        WebGLRenderingContext.prototype.shaderSource=function(s,source){
          return shader.call(this,s,source.replace('exp(-depth/max(1.,w*.075))','(1.-smoothstep(0.,2.,depth))'));
        };
        regression=new KMReaderCurlSurface();
      }finally{WebGLRenderingContext.prototype.shaderSource=shader;}
      try{return {current,regression:await probe(regression)};}finally{regression.dispose();}
    }""")
    output=Path('artifacts/epub-curl-regressions');output.mkdir(parents=True,exist_ok=True)
    (output / f'front-shadow-{width}-{rtl}.json').write_text(json.dumps(front_shade,indent=2))
    increases=lambda rows: max(b-a for sample in rows for a,b in zip(sample['row'],sample['row'][1:]))
    assert increases(front_shade['current'])<=4, ('Bright seam on the bent front',front_shade)
    assert increases(front_shade['regression'])>4, ('Pixel probe missed the former 2px cutoff',front_shade)
    # A decode that never completes must not keep a canceled pointer in the
    # operation queue. Reflow ensures no previously cached snapshot can mask it.
    page.evaluate("""async () => {
      window.realDecode=HTMLImageElement.prototype.decode;
      HTMLImageElement.prototype.decode=()=>new Promise(()=>{});
      await reader.preferences({...JSON.parse(JSON.stringify(window.testPreferences)),fontSize:23,advancedLayout:true});
    }""")
    saved = page.evaluate('reader.position().start.cfi')
    page.mouse.move(xcoord(width - 6), height * .55)
    page.mouse.down()
    page.mouse.move(xcoord(width * .7), height * .55, steps=7)
    page.wait_for_function('() => !!document.getElementById("page-gesture")')
    page.mouse.move(xcoord(width * .98), height * .55, steps=5)
    page.mouse.up()
    page.wait_for_function('() => !document.getElementById("page-gesture")', timeout=1000)
    assert page.evaluate('reader.position().start.cfi') == saved
    page.evaluate('() => {HTMLImageElement.prototype.decode=realDecode;}')
    page.evaluate('reader.next()')
    assert page.evaluate('reader.position().start.cfi') != saved, 'Canceled decode locked the navigation queue'
    assert not errors, errors
    browser.close()
print('First drag on each page reused prepared GPU textures; front/destination pixels, cancel/retry and focus recovery passed', width, rtl)
