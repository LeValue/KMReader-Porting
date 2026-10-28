"""Exercise the shipped reader scripts against a real Chromium layout engine."""
import json
import sys
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width': 420, 'height': 700})
    failures = []
    page.on('pageerror', lambda error: failures.append(str(error)))
    page.add_init_script("window.readerMessages=[]; addEventListener('readerEvent', event=>readerMessages.push(event.detail));")
    page.goto(url)
    page.evaluate('(config)=>window.reader.open(config)', config)
    page.wait_for_function("readerMessages.some(m=>m.type==='ready')")
    first = page.evaluate("readerMessages.filter(m=>m.type==='position').at(-1)")
    assert first['pages'] > 1, first
    assert first['changed'] is False
    page.set_viewport_size({'width': 421, 'height': 699})
    page.evaluate('window.reader.next()')
    second = page.evaluate("readerMessages.filter(m=>m.type==='position').at(-1)")
    assert second['cfi'] != first['cfi'] and second['changed'] is True, second
    assert second['progression'] > first['progression'], (first, second)
    import base64
    snapshot = 'data:image/png;base64,' + base64.b64encode(page.screenshot()).decode()
    for style in ['slide', 'cover', 'curl']:
        page.evaluate('(value)=>window.reader.turn(value)', {'delta': 1, 'style': style, 'snapshot': snapshot})
        assert not page.evaluate("Boolean(document.querySelector('#page-transition'))")
    page.evaluate('readerMessages.length=0')
    preferences = {**config['preferences'], 'fontSize': 28, 'columns': 1}
    page.evaluate('(value)=>window.reader.preferences(value)', preferences)
    assert not page.evaluate("readerMessages.some(m=>m.type==='position' && m.changed)")
    page.set_viewport_size({'width': 1100, 'height': 650})
    page.wait_for_timeout(400)
    page.evaluate('(value)=>window.reader.preferences(value)', {**preferences, 'columns': 2})
    matches = page.evaluate("window.reader.search('Paragraph 40')")
    assert matches and matches[0]['cfi'].startswith('epubcfi('), matches
    page.evaluate('(cfi)=>window.reader.display(cfi)', matches[0]['cfi'])
    searched = page.evaluate("readerMessages.filter(m=>m.type==='position').at(-1)")
    assert searched['changed'] is True
    page.evaluate('(value)=>window.reader.preferences(value)', {**preferences, 'flow': 'scrolled'})
    page.evaluate('readerMessages.length=0')
    page.mouse.move(250, 250)
    page.mouse.wheel(0, 700)
    page.wait_for_timeout(1000)
    scrolled = page.evaluate("readerMessages.filter(m=>m.type==='position').at(-1)")
    assert scrolled and scrolled['changed'] is True and scrolled['progression'] > searched['progression'], scrolled
    page.evaluate('(url)=>window.reader.openAuxiliary(url)', config['footnote'])
    assert page.evaluate("document.querySelector('#auxiliary').contentDocument.querySelector('#note').textContent") == 'Supplementary note'
    page.evaluate('window.reader.closeAuxiliary()')
    assert not page.evaluate("Boolean(document.querySelector('#auxiliary'))")
    assert not failures, failures
    print(json.dumps({'paged': True, 'reflowWithoutProgress': True, 'columns': True, 'search': len(matches), 'scrollProgress': True, 'footnotes': True}))
    browser.close()
