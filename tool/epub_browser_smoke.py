"""Exercise the shipped reader scripts against a real Chromium layout engine."""
import json
import sys
import time
from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width': 420, 'height': 700})
    def wait_for_chapter(name):
        deadline = time.monotonic() + 10
        while not page.evaluate('(name)=>window.reader.position().start.href.endsWith(name)', name):
            if time.monotonic() >= deadline:
                raise AssertionError({'expectedChapter': name, 'position': page.evaluate('window.reader.position()'), 'failures': failures})
            page.wait_for_timeout(100)
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
    end_matches = page.evaluate("window.reader.search('Paragraph 119')")
    first_chapter_end = next(match for match in end_matches if match['href'].endswith('one.xhtml'))
    page.evaluate('(cfi)=>window.reader.display(cfi)', first_chapter_end['cfi'])
    page.mouse.wheel(0, 1200)
    wait_for_chapter('two.xhtml')
    page.wait_for_timeout(300)
    crossed = page.evaluate("readerMessages.filter(m=>m.type==='position' && m.changed).at(-1)")
    assert crossed['href'].endswith('two.xhtml') and crossed['changed'] is True, crossed
    page.mouse.wheel(0, -1200)
    wait_for_chapter('one.xhtml')
    page.wait_for_timeout(300)
    page.evaluate('readerMessages.length=0')
    page.evaluate('(value)=>window.reader.preferences(value)', {**preferences, 'flow': 'scrolled', 'fontSize': 24})
    assert not page.evaluate("readerMessages.some(m=>m.type==='position' && m.changed)")
    for _ in range(2):
        page.evaluate('(value)=>window.reader.preferences(value)', {**preferences, 'flow': 'paged'})
        assert page.evaluate("window.reader.position().start.href.endsWith('one.xhtml')")
        page.evaluate('(value)=>window.reader.preferences(value)', {**preferences, 'flow': 'scrolled'})
    assert not page.evaluate("readerMessages.some(m=>m.type==='position' && m.changed)")
    page.evaluate('(url)=>window.reader.openAuxiliary(url)', config['footnote'])
    assert page.evaluate("document.querySelector('#auxiliary').contentDocument.querySelector('#note').textContent") == 'Supplementary note'
    page.evaluate('window.reader.closeAuxiliary()')
    assert not page.evaluate("Boolean(document.querySelector('#auxiliary'))")
    page.evaluate('window.reader.destroy()')
    page.wait_for_timeout(350)
    page.reload()
    resume = {**config, 'preferences': {**preferences, 'flow': 'scrolled'}, 'cfi': crossed['cfi'], 'href': crossed['href']}
    page.evaluate('(value)=>window.reader.open(value)', resume)
    restored = page.evaluate("readerMessages.filter(m=>m.type==='position').at(-1)")
    assert restored['href'].endswith('two.xhtml') and restored['changed'] is False, restored
    assert abs(restored['progression'] - crossed['progression']) < .02, (crossed, restored)
    assert not page.evaluate("readerMessages.some(m=>m.type==='position' && m.changed)")
    page.mouse.wheel(0, -1200)
    wait_for_chapter('one.xhtml')
    page.evaluate('window.reader.destroy()')
    page.wait_for_timeout(350)
    assert not failures, failures
    print(json.dumps({'paged': True, 'reflowWithoutProgress': True, 'columns': True, 'search': len(matches), 'scrollProgress': True, 'continuousChapters': True, 'flowSwitchResume': True, 'coldScrollCfiResume': True, 'footnotes': True}))
    browser.close()
