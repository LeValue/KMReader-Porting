#!/usr/bin/env python3
"""Measure shipped EPUB assets on generated prose with optional CPU throttling.

Run baseline and candidate sequentially with identical --paragraphs/--cpu-rate.
These are browser command/task measurements, not native device display FPS.
"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import tempfile
import threading
import time

from playwright.sync_api import sync_playwright


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *unused):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, default=Path('assets/epub'))
    parser.add_argument('--paragraphs', type=int, default=3000)
    parser.add_argument('--cpu-rate', type=float, default=6)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.paragraphs < 100 or not 1 <= args.cpu_rate <= 20:
        parser.error('Use at least 100 paragraphs and a CPU rate between 1 and 20')
    with tempfile.TemporaryDirectory(prefix='kmreader-pipeline-') as directory:
        root = Path(directory)
        shutil.copytree(args.assets, root / 'reader')
        (root / 'reader/index.html').write_text(
            '<html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<link rel="stylesheet" href="reader.css"></head><body><div id="viewer"></div>'
            '<script src="epub.min.js"></script><script src="reader.js"></script></body></html>')
        (root / 'book').mkdir()
        (root / 'book/package.opf').write_text(
            '<package unique-identifier="uid"><metadata><identifier id="uid">pipeline</identifier>'
            '<language>en</language><title>Pipeline benchmark</title></metadata><manifest>'
            '<item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>'
            '<item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>'
            '</manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>')
        paragraphs = ''.join(f'<p>Paragraph {i}. ' +
                             'A reader should remain responsive while displaying text. ' * 3 + '</p>'
                             for i in range(args.paragraphs))
        for chapter in ['one', 'two']:
            (root / f'book/{chapter}.xhtml').write_text(
                '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>'
                f'<body><div class="chapter">{paragraphs}</div></body></html>')
        server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=root))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f'http://127.0.0.1:{server.server_port}'
        preferences = dict(flow='paged', font='publisher', theme='white', animate=True,
                          advancedLayout=True, fontWeight=0, fontSize=19, lineHeight=1.65,
                          margin=24, columns=1, alignment='publisher', paragraphSpacing=.5,
                          indent=0, letterSpacing=0, wordSpacing=0, transition='none',
                          tapScroll=80, backgroundColor='#ffffff', textColor='#000000')
        report = dict(cpuRate=args.cpu_rate, paragraphsPerChapter=args.paragraphs,
                      viewport=dict(width=390, height=780), cases=[])
        try:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
                report['engine'] = browser.version
                for mode in ['none', 'curl', 'vertical']:
                    page = browser.new_page(viewport=report['viewport'])
                    errors = []
                    page.on('pageerror', lambda error: errors.append(str(error)))
                    cdp = page.context.new_cdp_session(page)
                    cdp.send('Emulation.setCPUThrottlingRate', {'rate': args.cpu_rate})
                    cdp.send('Performance.enable')
                    page.goto(base + '/reader/')
                    page.evaluate('''() => {
                      const render=ePub.Book.prototype.renderTo;
                      ePub.Book.prototype.renderTo=function(...args){return window.rendition=render.apply(this,args);};
                    }''')
                    prefs = {**preferences, 'flow': 'scrolled' if mode == 'vertical' else 'paged',
                             'transition': 'curl' if mode == 'curl' else 'none'}
                    start = time.monotonic()
                    page.evaluate('''c=>Promise.race([reader.open(c),new Promise((_,reject)=>
                      setTimeout(()=>reject(Error('Reader open timeout')),30000))])''',
                                  dict(url=base + '/book/package.opf', nonce='benchmark',
                                       preferences=prefs, direction='ltr', href='one.xhtml'))
                    opened = (time.monotonic() - start) * 1000
                    # No warm-up delay/turn before the first input.
                    turns = page.evaluate('''async style=>{
                      const samples=[];
                      for(let i=0;i<5;i++){
                        const cfi=reader.position().start.cfi,start=performance.now();
                        await reader.turn({delta:1,style});samples.push(performance.now()-start);
                        if(reader.position().start.cfi===cfi)throw Error('Turn did not advance');
                        await new Promise(resolve=>setTimeout(resolve,650));
                      }
                      return samples;
                    }''', prefs['transition'])
                    scroll = None
                    if mode == 'vertical':
                        def metrics():
                            return {v['name']: v['value'] for v in cdp.send('Performance.getMetrics')['metrics']}
                        before = metrics()
                        page.evaluate('''async()=>{
                          for(let i=0;i<40;i++){
                            rendition.manager.container.scrollBy(0,30);
                            await new Promise(resolve=>setTimeout(resolve,35));
                          }
                          await new Promise(resolve=>setTimeout(resolve,150));
                        }''')
                        after = metrics()
                        scroll = dict(taskMs=(after['TaskDuration'] - before['TaskDuration']) * 1000,
                                      layouts=after['LayoutCount'] - before['LayoutCount'])
                    before = {v['name']: v['value'] for v in cdp.send('Performance.getMetrics')['metrics']}
                    page.wait_for_timeout(1500)
                    after = {v['name']: v['value'] for v in cdp.send('Performance.getMetrics')['metrics']}
                    case = dict(mode=mode, openMs=opened, firstTurnMs=turns[0], followingTurnsMs=turns[1:],
                                verticalScroll=scroll, idleTaskMs=(after['TaskDuration'] - before['TaskDuration']) * 1000)
                    assert not errors, errors
                    report['cases'].append(case)
                    print(json.dumps(case), flush=True)
                    page.evaluate('reader.destroy()')
                    page.close()
                browser.close()
            args.output.write_text(json.dumps(report, indent=2) + '\n')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
