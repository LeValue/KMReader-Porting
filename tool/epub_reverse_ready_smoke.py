"""A first backward curl on a dense screen must reuse pre-rasterized text."""
import json,sys
from playwright.sync_api import sync_playwright
url,config=sys.argv[1],json.loads(sys.argv[2])
with sync_playwright() as pw:
    browser=pw.chromium.launch(headless=True,args=['--no-sandbox'])
    page=browser.new_page(viewport={'width':393,'height':844},device_scale_factor=3,is_mobile=True,has_touch=True)
    page.goto(url)
    page.evaluate('''()=>{
      window.warms=0;window.work={decode:0,serialize:0};
      for(const [prototype,name,key] of [[XMLSerializer.prototype,'serializeToString','serialize'],[HTMLImageElement.prototype,'decode','decode']]){
        const original=prototype[name];prototype[name]=function(...args){work[key]++;return original.apply(this,args);};
      }
      const render=KMReaderCurlSurface.prototype.render;
      KMReaderCurlSurface.prototype.render=function(p,...args){const value=render.call(this,p,...args);if(this===KMReaderCurlSurface.shared&&!this.effect&&p===0)warms++;return value;};
      const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=function(...args){window.effect=this;return start.apply(this,args);};
    }''')
    config['preferences'].update(transition='curl',flow='paged',followGesture=True)
    page.evaluate('(c)=>reader.open(c)',config)
    page.wait_for_function('()=>warms>0')
    old=page.evaluate('warms')
    page.evaluate('reader.next()')
    page.wait_for_function('(n)=>warms>n',arg=old)
    saved=page.evaluate('reader.position().start.cfi')
    page.evaluate('window.beforeWork={...work}')
    touch=page.context.new_cdp_session(page)
    touch.send('Input.dispatchTouchEvent',{'type':'touchStart','touchPoints':[{'x':6,'y':422}]})
    for x in [25,55,100,180,240]:touch.send('Input.dispatchTouchEvent',{'type':'touchMove','touchPoints':[{'x':x,'y':422}]})
    page.wait_for_function('()=>effect?.ready&&effect.progress>.1')
    assert page.evaluate('JSON.stringify(beforeWork)===JSON.stringify(work)'),page.evaluate('({beforeWork,work})')
    assert page.evaluate('reader.position().start.cfi')==saved
    touch.send('Input.dispatchTouchEvent',{'type':'touchEnd','touchPoints':[]})
    page.wait_for_function('()=>!document.getElementById("page-gesture")')
    assert page.evaluate('reader.position().start.cfi')!=saved
    browser.close()
print('Backward native-density curl reused decoded text without foreground serialization')
