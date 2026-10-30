#!/usr/bin/env python3
"""Check fixed-layout artwork and vertical CJK in the bundled EPUB engine."""
import json
import sys

from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport=config.get('viewport', {'width': 390, 'height': 780}))
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.add_init_script("window.readerMessages=[]; addEventListener('readerEvent', event=>readerMessages.push(event.detail));")
    page.goto(url)
    if config.get('kind') != 'vertical' or config['preferences']['flow'] == 'paged':
        page.evaluate("""() => {
            const renderTo = ePub.Book.prototype.renderTo;
            ePub.Book.prototype.renderTo = function(...args) {
                const rendition = renderTo.apply(this, args);
                window.fixtureRendition = rendition;
                const report = rendition.reportLocation;
                const pending = [];
                rendition.reportLocation = () => {pending.push(() => report.call(rendition)); return Promise.resolve();};
                window.releaseInitialReports = () => {rendition.reportLocation = report; for (const job of pending) job();};
                return rendition;
            };
        }""")
    page.evaluate('(config)=>window.reader.open(config)', config)
    page.wait_for_function("readerMessages.some(m=>m.type==='ready')")
    assert page.evaluate('Boolean(window.reader.position()?.start?.cfi)'), 'Reader readiness needs a real initial viewport locator'
    page.evaluate('window.releaseInitialReports?.()')
    # Epub.js may clear its inline stage height during layout. Its scrollport
    # must stay bounded to the viewport rather than growing to chapter height.
    page.evaluate("document.querySelector('.epub-container').style.removeProperty('height')")
    bounds = page.evaluate("({height:document.querySelector('.epub-container').clientHeight, viewport:innerHeight})")
    assert abs(bounds['height'] - bounds['viewport']) <= 1, bounds


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
        # Some Android caret APIs are missing or keep returning a paragraph
        # start across several pages. Position tracking must use visible text.
        if page.viewport_size['width'] == 390:
            frame.evaluate('document.caretRangeFromPoint = null')
        elif page.viewport_size['width'] == 411:
            frame.evaluate("document.caretRangeFromPoint = () => new parent.ePub.CFI(parent.reader.position().start.cfi).toRange(document)")

        first = page.evaluate('window.reader.position().start')
        if config['preferences']['flow'] == 'scrolled':
            page.mouse.move(200, 300)
            page.mouse.wheel(-900, 0)
            page.wait_for_timeout(600)
        else:
            assert first['displayed']['total'] > 1, first
            # Android WebView can report isPaginated=false while the CJK
            # publication still has paged flow and a vertical manager axis.
            # The engine must own page advancement in that case.
            page.evaluate("""() => {
                const manager = window.fixtureRendition.manager;
                const paginated = manager.isPaginated;
                const next = manager.next.bind(manager);
                window.fixturePagedTurns = 0;
                manager.isPaginated = false;
                manager.next = (...args) => {
                    window.fixturePagedTurns++;
                    manager.isPaginated = paginated;
                    manager.next = next;
                    return next(...args);
                };
            }""")
            # Live viewport transitions must not cover the publication with a
            # native screenshot: that invalidated caret hit testing and delayed
            # real WebView pagination until the covering image was removed.
            page.evaluate("""() => {
                const manager = window.fixtureRendition.manager;
                const run = manager.next.bind(manager);
                manager.next = (...args) => {
                    if (document.getElementById('page-transition')) {
                        throw new Error('A snapshot must never occlude the live EPUB');
                    }
                    return run(...args);
                };
            }""")
            page.evaluate("window.reader.turn({delta:1,style:'slide'})")
            assert page.evaluate('window.fixturePagedTurns') == 1
        second = page.evaluate('window.reader.position().start')
        assert second['cfi'] != first['cfi'], (first, second)
        if config['preferences']['flow'] == 'paged':
            # Delayed native RAF reports may carry the coarse paragraph start
            # after turn() has already committed a visible character locator.
            page.evaluate('''cfi => {
                const current=reader.position();
                fixtureRendition.emit('relocated', {...current,start:{...current.start,cfi}});
            }''', first['cfi'])
            assert page.evaluate('reader.position().start.cfi') == second['cfi']
            page.wait_for_timeout(150)
            assert page.evaluate('reader.position().start.cfi') == second['cfi']
        for font_size in [52, 60, 76]:
            saved_turn = page.evaluate('window.reader.position().start.cfi')
            page.evaluate('(value)=>window.reader.preferences(value)', {**config['preferences'], 'fontSize': font_size})
            anchor_rect = frame.evaluate('(cfi)=>new parent.ePub.CFI(cfi).toRange(document).getBoundingClientRect().toJSON()', saved_turn)
            frame_rect = frame.frame_element().bounding_box()
            anchor_x, anchor_y = frame_rect['x'] + anchor_rect['x'], frame_rect['y'] + anchor_rect['y']
            assert -1 <= anchor_x < page.viewport_size['width'] + 1 and -1 <= anchor_y < page.viewport_size['height'] + 1, {'font': font_size, 'anchor': anchor_rect, 'frame': frame_rect}
            page.evaluate('readerMessages.length=0')
            if config['preferences']['flow'] == 'paged':
                page.evaluate("window.reader.turn({delta:1,style:'slide'})")
            else:
                page.evaluate('window.reader.next()')
            advanced = page.evaluate("readerMessages.filter(m=>m.type==='position' && m.changed).at(-1)")
            if not advanced:
                print('caret-diagnostics', frame.evaluate("""() => {
                  const f = frameElement.getBoundingClientRect(), v = parent.document.querySelector('.epub-container').getBoundingClientRect();
                  return [1, 21, 28, 44, 80].map(inset => {
                    const x = v.right - f.left - inset, y = v.top - f.top + 25;
                    const range = document.caretRangeFromPoint?.(x,y);
                    return {x,y,node:range?.startContainer.parentElement?.id,offset:range?.startOffset,rect:range?.getBoundingClientRect().toJSON(),frame:f.toJSON(),viewport:v.toJSON()};
                  });
                }"""))
                page.screenshot(path=f"/tmp/km-cjk-fail-{page.viewport_size['width']}-{config['preferences']['flow']}.png")
            assert advanced and advanced['cfi'] != saved_turn, {'font': font_size, 'before': saved_turn, 'after': page.evaluate('window.reader.position().start'), 'messages': page.evaluate('readerMessages')}
        match = page.evaluate("window.reader.search('縦書き段落47')")[0]
        page.evaluate('(cfi)=>window.reader.display(cfi)', match['cfi'])
        box = frame.locator('#p47').bounding_box()
        assert box and box['x'] < page.viewport_size['width'] and box['x'] + box['width'] > 0 and box['y'] < page.viewport_size['height'] and box['y'] + box['height'] > 0, box
        saved = page.evaluate('window.reader.position().start.cfi')
        page.evaluate('readerMessages.length=0')
        page.evaluate('(value)=>window.reader.preferences(value)', {**config['preferences'], 'fontSize': 26})
        anchor = frame.evaluate('(cfi)=>new parent.ePub.CFI(cfi).toRange(document).getBoundingClientRect().toJSON()', saved)
        viewport = frame.frame_element().bounding_box()
        x, y = viewport['x'] + anchor['x'], viewport['y'] + anchor['y']
        assert -1 <= x < page.viewport_size['width'] + 1 and -1 <= y < page.viewport_size['height'] + 1, (anchor, viewport)
        assert not page.evaluate("readerMessages.some(m=>m.type==='position' && m.changed)")
        page.evaluate("window.reader.display('one.xhtml#p80')")
        box = frame.locator('#p80').bounding_box()
        assert box and box['x'] < page.viewport_size['width'] and box['x'] + box['width'] > 0 and box['y'] < page.viewport_size['height'] and box['y'] + box['height'] > 0, box
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
    # The queued reporting future can finish before its relocation callback.
    # Hold reporting until after asserting the completed turn's current locator.
    page.evaluate("""() => {
        const rendition = window.fixtureRendition;
        const report = rendition.reportLocation;
        const pending = [];
        const delayed = () => {pending.push(() => report.call(rendition)); return Promise.resolve();};
        rendition.reportLocation = delayed;
        if (rendition.reportLocation !== delayed) throw Error('Report hook was not installed');
        window.releaseReports = () => {rendition.reportLocation = report; for (const job of pending) job();};
    }""")
    page.evaluate('window.reader.next()')
    assert page.evaluate("window.reader.position().start.href.endsWith('two.xhtml')")
    assert page.evaluate("readerMessages.some(m=>m.type==='position' && m.changed)")
    page.evaluate('window.releaseReports()')
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
