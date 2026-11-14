"""Probe glyph alignment on fractional Android pixel grids, in both directions."""
import io,json,sys
from PIL import Image,ImageChops,ImageStat
from playwright.sync_api import sync_playwright
url,config=sys.argv[1],json.loads(sys.argv[2])
with sync_playwright() as pw:
    browser=pw.chromium.launch(headless=True,args=['--no-sandbox'])
    page=browser.new_page(viewport={'width':393,'height':852},device_scale_factor=2.625,is_mobile=True,has_touch=True)
    page.goto(url)
    page.evaluate('''()=>{
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=function(...args){window.capture=this.capture;return start.apply(this,args);};
    }''')
    config['preferences'].update(transition='curl',fontSize=22.25,margin=24.5)
    page.evaluate('(c)=>reader.open(c)',config)
    page.evaluate('reader.turn({delta:1,style:"curl"})')
    page.evaluate('reader.suspendInput(true)')
    results=[]
    for top in [0,.375]:
        page.evaluate('''async ({top,prefs})=>{
          document.querySelector('#viewer').style.cssText=`position:fixed;top:${top}px;height:calc(100% - ${top}px)`;
          await reader.preferences({...prefs,transition:'curl',fontSize:22.25,margin:24.5});
        }''',{'top':top,'prefs':config['preferences']})
        live=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
        page.evaluate('''async()=>{
          window.texture=await capture();window.probe=new KMReaderCurlSurface();await probe.whenReady();
          probe.upload(texture,texture,innerWidth,innerHeight);document.body.append(probe.canvas);
        }''')
        for direction in [1,-1]:
            page.evaluate('(s)=>probe.render(0,false,s,0,.5)',direction)
            raster=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
            scores=[]
            for dy in range(-4,5):
                box=(80,100,live.width-80,live.height-100)
                reference=live.crop(box)
                sample=raster.crop((box[0],box[1]+dy,box[2],box[3]+dy))
                scores.append((max(ImageStat.Stat(ImageChops.difference(reference,sample)).mean),dy))
            best=min(scores)
            results.append({'top':top,'direction':direction,'best_shift_y':best[1],'error':best[0]})
        page.evaluate('()=>{probe.dispose();}')
    print(json.dumps(results))
    assert all(row['best_shift_y']==0 for row in results),results
    browser.close()
