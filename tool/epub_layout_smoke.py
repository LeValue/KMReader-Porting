#!/usr/bin/env python3
"""Check fixed-layout artwork and vertical CJK in the bundled EPUB engine."""
import json
import sys

from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width': 390, 'height': 780})
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.add_init_script("window.readerMessages=[]; addEventListener('readerEvent', event=>readerMessages.push(event.detail));")
    page.goto(url)
    page.evaluate('(config)=>window.reader.open(config)', config)
    page.wait_for_function("readerMessages.some(m=>m.type==='ready')")

    def check_authored():
        frame = next(frame for frame in page.frames if frame.locator('#label').count())
        values = frame.locator('#label').evaluate('''element => {
          const style = getComputedStyle(element);
          return {font: style.fontSize, color: style.color, left: style.left, top: style.top};
        }''')
        assert values == {'font': '18px', 'color': 'rgb(17, 34, 51)', 'left': '120px', 'top': '200px'}, values

    if config.get('kind') == 'vertical':
        frame = next(frame for frame in page.frames if frame.locator('#p0').count())
        mode = frame.evaluate('getComputedStyle(document.documentElement).writingMode')
        assert mode == 'vertical-rl', mode
        assert frame.evaluate('getComputedStyle(document.body).direction') == 'ltr'
        first = page.evaluate('window.reader.position().start')
        if config['preferences']['flow'] == 'scrolled':
            page.mouse.move(200, 300)
            page.mouse.wheel(-900, 0)
            page.wait_for_timeout(600)
        else:
            assert first['displayed']['total'] > 1, first
            page.evaluate('window.reader.next()')
        second = page.evaluate('window.reader.position().start')
        assert second['cfi'] != first['cfi'], (first, second)
        match = page.evaluate("window.reader.search('縦書き段落47')")[0]
        page.evaluate('(cfi)=>window.reader.display(cfi)', match['cfi'])
        box = frame.locator('#p47').bounding_box()
        assert box and box['x'] < 390 and box['x'] + box['width'] > 0 and box['y'] < 780 and box['y'] + box['height'] > 0, box
        saved = page.evaluate('window.reader.position().start.cfi')
        page.evaluate('readerMessages.length=0')
        page.evaluate('(value)=>window.reader.preferences(value)', {**config['preferences'], 'fontSize': 26})
        anchor = frame.evaluate('(cfi)=>new parent.ePub.CFI(cfi).toRange(document).getBoundingClientRect().toJSON()', saved)
        viewport = frame.frame_element().bounding_box()
        x, y = viewport['x'] + anchor['x'], viewport['y'] + anchor['y']
        assert -1 <= x < 391 and -1 <= y < 781, (anchor, viewport)
        assert not page.evaluate("readerMessages.some(m=>m.type==='position' && m.changed)")
        page.evaluate("window.reader.display('one.xhtml#p80')")
        box = frame.locator('#p80').bounding_box()
        assert box and box['x'] < 390 and box['x'] + box['width'] > 0 and box['y'] < 780 and box['y'] + box['height'] > 0, box
        page.evaluate('window.reader.destroy()')
        page.wait_for_timeout(200)
        assert not errors, errors
        browser.close()
        print('Vertical CJK pagination, search visibility and CFI preservation passed')
        sys.exit(0)

    check_authored()
    if config['preferences']['flow'] == 'scrolled':
        assert not page.evaluate("readerMessages.filter(m=>m.type==='position').at(-1).atEnd")
    first = page.evaluate('window.reader.position().start')
    page.evaluate('readerMessages.length=0')
    page.evaluate('(value)=>window.reader.preferences(value)', {
        **config['preferences'], 'fontSize': 32, 'lineHeight': 2.5, 'margin': 80,
        'indent': 3, 'paragraphSpacing': 3, 'theme': 'black', 'columns': 1,
    })
    check_authored()
    assert not page.evaluate("readerMessages.some(m=>m.type==='position' && m.changed)")
    assert page.evaluate('window.reader.position().start.cfi') == first['cfi']
    page.evaluate('window.reader.next()')
    assert page.evaluate("window.reader.position().start.href.endsWith('two.xhtml')")
    check_authored()
    page.set_viewport_size({'width': 1100, 'height': 700})
    page.wait_for_timeout(600)
    check_authored()
    page.evaluate('window.reader.previous()')
    assert page.evaluate("window.reader.position().start.href.endsWith('one.xhtml')")
    page.evaluate('window.reader.destroy()')
    page.wait_for_timeout(200)
    assert not errors, errors
    browser.close()
    print('Fixed-layout artwork, authored text, CFI, navigation and resizing passed')
