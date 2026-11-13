"""Chapter-boundary touch input must outlive preview and remain usable afterward."""
import json
import sys
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width':394,'height':844},has_touch=True,is_mobile=True,device_scale_factor=3)
    page.set_default_timeout(10000)
    page.goto(url)
    page.evaluate('(c)=>reader.open(c)',config)
    touch=page.context.new_cdp_session(page)
    for iteration in range(3):
        page.evaluate('reader.display("two.xhtml")')
        for start,end in [(6,240),(388,135)]:
            saved=page.evaluate('reader.position().start.cfi')
            page.evaluate('()=>{window.inputChapter=document.querySelector("#viewer iframe");}')
            touch.send('Input.dispatchTouchEvent',{'type':'touchStart','touchPoints':[{'x':start,'y':422}]})
            for step in range(1,9):
                touch.send('Input.dispatchTouchEvent',{'type':'touchMove','touchPoints':[{'x':start+(end-start)*step/8,'y':422}]})
            page.wait_for_function('()=>!!document.getElementById("page-gesture")')
            assert page.evaluate('inputChapter.isConnected'), 'Preview destroyed the touch input document'
            assert page.evaluate('reader.position().start.cfi')==saved, 'Chapter committed before touch release'
            touch.send('Input.dispatchTouchEvent',{'type':'touchEnd','touchPoints':[]})
            page.wait_for_function('()=>!document.getElementById("page-gesture")')
            assert page.evaluate('reader.position().start.cfi')!=saved, 'Released chapter turn did not commit'
        page.evaluate('reader.previous()')
        page.evaluate('reader.next()')
    page.evaluate('reader.destroy()')
    browser.close()
print('Six touch chapter crossings and subsequent direct navigation passed')
