"""Verify the optional original-position bridge against the shipped renderer."""
import json
import base64
import io
from PIL import Image, ImageChops, ImageStat
import sys
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width':390,'height':780})
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.add_init_script("window.events=[];addEventListener('readerEvent',e=>events.push(e.detail));")
    page.goto(url)
    page.evaluate("""() => { const start=KMReaderSheetEffect.prototype.start;
      KMReaderSheetEffect.prototype.start=function(...args){window.kindleCapture=this.capture;return start.apply(this,args);};
    }""")
    config['preferences']['transition']='curl'
    page.evaluate('(config)=>reader.open(config)', config)
    page.wait_for_function("() => events.some(e=>e.type==='ready')")
    first = page.evaluate("events.filter(e=>e.type==='position').at(-1)")
    assert first['kindlePosition'] == 102, first
    assert not first['changed'], first
    original = page.evaluate("document.querySelector('iframe').contentDocument.body.textContent")
    page.evaluate("""() => {
      const doc = document.querySelector('iframe').contentDocument;
      const text = doc.querySelector('#mapped').firstChild;
      const range = doc.createRange();
      range.setStart(text, 3);
      range.setEnd(text, 6);
      doc.getSelection().removeAllRanges();
      doc.getSelection().addRange(range);
    }""")
    page.wait_for_function("() => events.some(e=>e.type==='selection'&&e.text==='old')")
    selected = page.evaluate("events.filter(e=>e.type==='selection'&&e.text==='old').at(-1)")
    assert selected['kindleStart'] == 102 and selected['kindleEnd'] == 105, selected
    assert selected['cfi'].startswith('epubcfi(') and selected['rangeCfi'].count(',') == 2, selected
    assert len(selected['anchor']) == 4, selected
    assert page.evaluate('''() => {
      const doc=document.querySelector('iframe').contentDocument;
      return !doc.body.dispatchEvent(new MouseEvent('contextmenu', {
        bubbles:true, cancelable:true, clientX:23, clientY:34
      }));
    }'''), 'The native context menu was not prevented'
    anchored = page.evaluate("events.filter(e=>e.type==='selection'&&e.context).at(-1)")
    assert anchored['anchor'][0] == anchored['anchor'][2], anchored
    page.evaluate('reader.clearSelection()')
    page.evaluate("(rangeCfi) => reader.annotations([{id:'local-note',type:'kindle.note',rangeCfi}])", selected['rangeCfi'])
    page.wait_for_function("() => !!document.querySelector('.kmreader-kindle-highlight')")
    assert page.evaluate('''cfi => {
      const doc=document.querySelector('iframe').contentDocument;
      const complete=new ePub.CFI(cfi).toRange(doc);
      const last=complete.cloneRange();
      last.setStart(last.endContainer,last.endOffset-1);
      const finalGlyph=last.getBoundingClientRect();
      const painted=document.querySelector('.kmreader-kindle-highlight rect').getBoundingClientRect();
      const frame=doc.defaultView.frameElement.getBoundingClientRect();
      doc.body.dispatchEvent(new MouseEvent('click',{bubbles:true,
        clientX:(finalGlyph.left+finalGlyph.right)/2,clientY:(finalGlyph.top+finalGlyph.bottom)/2}));
      return complete.toString()==='old' && painted.right+.5>=frame.left+finalGlyph.right;
    }''', selected['rangeCfi']), 'Highlight did not reach its exclusive endpoint'
    page.wait_for_function("() => events.some(e=>e.type==='openNote'&&e.id==='local-note')")
    assert original == page.evaluate("document.querySelector('iframe').contentDocument.body.textContent")
    page.evaluate("reader.annotations([{id:'synthetic-highlight', type:'kindle.highlight', locator:{href:'one.xhtml',id:'mapped',position:100,offset:2},endLocator:{href:'one.xhtml',id:'mapped',position:100,offset:15}}])")
    page.wait_for_function("() => !!document.querySelector('.kmreader-kindle-highlight')")
    assert original == page.evaluate("document.querySelector('iframe').contentDocument.body.textContent")
    page.evaluate('(value)=>reader.preferences(value)', {**config['preferences'],'fontSize':24,'margin':25})
    page.evaluate('reader.whenIdle()')
    reflow = page.evaluate("events.filter(e=>e.type==='position').at(-1)")
    assert reflow['kindlePosition'] == 102 and not reflow['changed'], reflow
    remote = {'href': 'one.xhtml', 'id': 'mapped', 'position': 100, 'offset': 6,
              'expectedCfi': reflow['cfi']}
    assert page.evaluate('(value)=>reader.resumeKindle(value)', remote)
    page.wait_for_timeout(250)
    latest = page.evaluate("events.filter(e=>e.type==='position').at(-1)")
    assert latest['kindlePosition'] == 106 and not latest['changed'], latest
    assert page.evaluate('(value)=>reader.resumeKindle(value)', remote) is None, 'Stale offer moved the reader'
    invalid = {**remote, 'href': 'two.xhtml', 'expectedCfi': latest['cfi']}
    assert page.evaluate('(value)=>reader.resumeKindle(value)', invalid) is None
    restored = page.evaluate("events.filter(e=>e.type==='position').at(-1)")
    assert restored['cfi'] == latest['cfi'] and not restored['changed'], restored
    across = {'href': 'two.xhtml', 'id': 'mapped-next', 'position': 20000,
              'offset': 4, 'expectedCfi': restored['cfi']}
    moved = page.evaluate('(value)=>reader.resumeKindle(value)', across)
    assert moved['kindlePosition'] == 20004 and not moved['changed'], moved
    assert page.evaluate("reader.position().start.index") == 1
    page.evaluate("document.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));")
    assert page.evaluate("events.some(e=>e.type==='turn'&&e.delta===1)")
    assert page.evaluate('(value)=>reader.resumeKindle(value)',
                         {**remote, 'expectedCfi': moved['cfi']})
    page.evaluate('reader.next()')
    page.evaluate('reader.whenIdle()')
    next_page = page.evaluate("events.filter(e=>e.type==='position'&&e.changed).at(-1)")
    assert next_page and next_page['kindlePosition'] > 102, next_page
    assert original == page.evaluate("document.querySelector('iframe').contentDocument.body.textContent")
    page.evaluate("reader.seek({href:'two.xhtml',progression:.5})")
    assert page.evaluate("reader.position().start.index") == 1
    page.evaluate("reader.seek({href:'one.xhtml',locator:{href:'one.xhtml',id:'mapped',position:100,offset:3}})")
    assert page.evaluate("events.filter(e=>e.type==='position').at(-1).kindlePosition") == 103
    page.evaluate("reader.turn({delta:1,style:'curl'})")
    page.evaluate('reader.suspendInput(true)')
    page.evaluate("reader.seek({href:'one.xhtml',locator:{href:'one.xhtml',id:'mapped',position:100,offset:2}})")
    encoded = page.evaluate("""async () => { const image=await kindleCapture();const canvas=document.createElement('canvas');
      canvas.width=image.width;canvas.height=image.height;canvas.getContext('2d').drawImage(image,0,0);return canvas.toDataURL('image/png').split(',')[1]; }""")
    captured=Image.open(io.BytesIO(base64.b64decode(encoded))).convert('RGB')
    live=Image.open(io.BytesIO(page.screenshot())).convert('RGB')
    assert max(ImageStat.Stat(ImageChops.difference(live,captured)).mean)<1, 'Highlight missing from curl texture'
    page.evaluate('reader.annotations([])')
    assert not page.locator('.kmreader-kindle-highlight').count(), 'Deleted cloud highlight remained visible'
    assert not errors, errors
    page.evaluate('reader.destroy()')
    # Ordinary publications never emit Kindle state.
    plain = {k:v for k,v in config.items() if k not in {'kindlePositions','kindleResume'}}
    page.goto(url)
    page.evaluate('(value)=>reader.open(value)', plain)
    page.wait_for_function("() => events.some(e=>e.type==='ready')")
    assert page.evaluate("events.filter(e=>e.type==='position').every(e=>!('kindlePosition' in e))")
    print(json.dumps({'unicode_resume':True,'reflow_retained':True,'navigation_mapped':True,'text_unchanged':True,'ordinary_reader_unchanged':True,'svg_annotations_preserve_text':True,'quick_seek':True}))
    browser.close()
