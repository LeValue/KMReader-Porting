#!/usr/bin/env python3
"""Trace trusted pointer drags and compare the flat curl handoff on one renderer."""

import argparse
import io
import json
import math
import os
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import urlopen

from PIL import Image
from playwright.sync_api import TimeoutError, sync_playwright


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets/epub'
TRACE = r'''() => {
  const renderTo=ePub.Book.prototype.renderTo;
  ePub.Book.prototype.renderTo=function(...args){return window.probeRendition=renderTo.apply(this,args);};
  let sample;
  const stamp=()=>performance.now();
  const start=KMReaderSheetEffect.prototype.start,animate=KMReaderSheetEffect.prototype.animateTo;
  const upload=KMReaderCurlSurface.prototype.upload,render=KMReaderCurlSurface.prototype.render;
  let warmed=0;
  KMReaderSheetEffect.prototype.start=function(move,preview){
    window.probeEffect=this;
    window.probeTextures=preview;
    let live=this.livePage;
    Object.defineProperty(this,'livePage',{get:()=>live,set:value=>{
      live=value;
      if(sample?.release!==undefined&&value===1)sample.ready=stamp();
    }});
    if(sample)sample.preview=!!preview;
    return start.call(this,move,preview);
  };
  KMReaderSheetEffect.prototype.animateTo=function(...args){
    if(sample?.hold){
      sample.settling=true;
      cancelAnimationFrame(this.tracking);this.tracking=0;this.pendingPoint=null;
      return new Promise(resolve=>window.probeFinish=resolve);
    }
    return animate.apply(this,args);
  };
  KMReaderCurlSurface.prototype.upload=function(...args){
    if(sample?.release!==undefined&&!sample.stable)sample.uploads++;
    return upload.apply(this,args);
  };
  const decode=HTMLImageElement.prototype.decode;
  HTMLImageElement.prototype.decode=function(){
    if(sample?.release!==undefined&&!sample.stable)sample.decodes++;
    return decode.call(this);
  };
  KMReaderCurlSurface.prototype.render=function(p,...args){
    const result=render.call(this,p,...args);
    if(!this.effect&&p===0)warmed++;
    if(this.effect&&sample?.release!==undefined&&!sample.stable&&p!==sample.progress){
      sample.frames.push(stamp());sample.progress=p;
    }
    return result;
  };
  window.probeWarm=()=>warmed;
  window.probeArm=hold=>{
    sample=window.probeSample={hold,frames:[],raf:[],uploads:0,decodes:0,trusted:false,input:{}};
    const initial=sample;
    function up(event){
      if(sample!==initial||sample.release!==undefined)return;
      sample.release=stamp();sample.trusted=event.isTrusted;sample.progress=window.probeEffect?.progress;
      const tick=now=>{
        if(sample!==initial||sample.stable)return;
        sample.raf.push(now);requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      const stop=new MutationObserver(()=>{
        if(document.getElementById('page-gesture'))return;
        stop.disconnect();
        requestAnimationFrame(()=>{sample.stable=stamp();});
      });
      stop.observe(document.body,{childList:true});
    }
    window.addEventListener('pointerup',up,{capture:true,once:true});
    for(const content of probeRendition.getContents()){
      content.document.addEventListener('pointerup',up,{capture:true,once:true});
      for(const type of ['pointerdown','pointermove','pointercancel']){
        content.document.addEventListener(type,event=>{
          if(sample===initial)sample.input[type]=[event.pointerType,Math.round(event.clientX),Math.round(event.clientY)];
        },{capture:true,once:true});
      }
    }
  };
  window.probePosition=()=>({cfi:reader.position().start.cfi,href:reader.position().start.href});
  window.probePlace=async kind=>{
    await reader.display(kind==='chapter-back'?'two.xhtml':'one.xhtml',false);
    if(kind==='chapter-forward'){
      const content=probeRendition.getContents()[0], range=content.document.createRange();
      range.selectNodeContents([...content.document.querySelectorAll('p')].at(-1));range.collapse(false);
      await reader.display(content.cfiFromRange(range),false);
    }else if(kind==='page-back')await reader.next();
    await reader.whenIdle();
  };
}'''


def fixture():
    stock = 'Le parole devono restare sulla stessa riga, anche quando la pagina successiva compare sotto la piega. '
    blocks = ''.join(f'<p>Riga {i} · {stock * (1+i%3)}Fine del passaggio.</p>' for i in range(66))
    publication = '''<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">km-handoff</dc:identifier>
      <dc:title>Curl fixture</dc:title><dc:language>it</dc:language></metadata>
      <manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
      <item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
      <item id="color" href="color.svg" media-type="image/svg+xml"/></manifest>
      <spine><itemref idref="one"/><itemref idref="two"/></spine></package>'''
    art = '<img alt="Fixture artwork" src="color.svg" style="width:33%;height:auto"/>'
    files = {'package.opf': publication, 'color.svg': '<svg xmlns="http://www.w3.org/2000/svg" width="150" height="70"><rect width="150" height="70" fill="#24829e"/></svg>'}
    for chapter in ['one', 'two']:
        body = (art + blocks) if chapter == 'two' else (blocks + art + '<p>Ultima riga di prova alla fine del capitolo.</p>')
        files[chapter + '.xhtml'] = ('<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title>'
                                   '<style>p{widows:2;orphans:2} img{display:block;margin:.35em auto}</style></head>'
                                   f'<body>{body}</body></html>')
    return {key: value.encode() for key, value in files.items()}


def serve(baseline):
    publication = fixture()
    html = b'''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
    <link rel="stylesheet" href="../vendor/reader.css"><div id="viewer"></div>
    <script src="../vendor/epub.min.js"></script><script src="../vendor/reader.js"></script>'''
    scripts = {'A': baseline, 'B': (ASSETS / 'reader.js').read_bytes()}
    shared = {name: (ASSETS / name).read_bytes() for name in ('reader.css', 'epub.min.js')}

    class Server(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split('?')[0].strip('/').split('/')
            kind = 'text/html'
            body = None
            if len(path) == 2 and path[0] in scripts and path[1] == 'reader':
                body = html
            elif len(path) == 3 and path[0] in scripts:
                label, folder, name = path
                if folder == 'vendor':
                    body = scripts[label] if name == 'reader.js' else shared.get(name)
                    kind = 'text/css' if name.endswith('.css') else 'text/javascript'
                elif folder == 'book':
                    body = publication.get(name)
                    kind = {'opf': 'application/oebps-package+xml', 'svg': 'image/svg+xml'}.get(name.split('.')[-1], 'application/xhtml+xml')
            if body is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def configure(page, origin, label, columns):
    page.goto(f'{origin}/{label}/reader/')
    page.evaluate(TRACE)
    page.evaluate('c=>reader.open(c)', {
        'url': f'{origin}/{label}/book/package.opf', 'nonce': 'handoff',
        'href': 'one.xhtml', 'language': 'it', 'direction': 'ltr',
        'preferences': {'columns': columns, 'theme': 'white', 'flow': 'paged', 'transition': 'curl',
                        'alignment': 'justify', 'animate': True, 'advancedLayout': True, 'fontSize': 20.25,
                        'lineHeight': 1.43, 'margin': 21.5, 'paragraphSpacing': .43, 'indent': .8,
                        'wordSpacing': 0, 'letterSpacing': 0, 'animationDuration': 380},
    })


def drag(page, cdp, case, touch, hold=False, cancel=False):
    warming = page.evaluate('probeWarm()')
    page.evaluate('kind=>probePlace(kind)', case)
    page.wait_for_function('n=>probeWarm()>n', arg=warming)
    before = page.evaluate('probePosition()')
    page.evaluate('hold=>probeArm(hold)', hold)
    w, h = page.evaluate('[innerWidth,innerHeight]')
    backward = case.endswith('back')
    inset = 16 if touch else 8
    start, end = (inset, w*.42) if backward else (w-inset, w*.58)
    y = h * .52

    def touch_event(kind, x):
        cdp.send('Input.dispatchTouchEvent', {'type': kind, 'touchPoints': [] if kind == 'touchEnd' else [{'x': x, 'y': y}]})

    if touch:
        touch_event('touchStart', start)
        # Cross the reader's start threshold on the first delivered move,
        # even when an emulator takes several frames to acknowledge input.
        for fraction in (.30, .45, .60, .74, .88, 1):
            touch_event('touchMove', start + (end-start)*fraction)
    else:
        page.mouse.move(start, y)
        page.mouse.down()
        page.mouse.move(end, y, steps=9)
    try:
        page.wait_for_function('probeEffect?.ready&&probeEffect.progress>.15')
    except TimeoutError as error:
        state = page.evaluate('''()=>({input:probeSample.input,shield:!!document.querySelector('#page-gesture'),
          ready:probeEffect?.ready,progress:probeEffect?.progress,viewport:[innerWidth,innerHeight,devicePixelRatio],
          visual:[visualViewport.width, visualViewport.height, visualViewport.scale]})''')
        raise RuntimeError(f'Curl did not follow the {case} drag: {state}') from error
    assert page.evaluate('probeSample.preview && !!document.querySelector("#page-gesture")')
    assert page.evaluate('probePosition()') == before
    if cancel:
        if touch:
            for i in range(1, 6):
                touch_event('touchMove', end + (start-end)*i/5)
        else:
            page.mouse.move(start, y, steps=5)
    page.wait_for_timeout(110)
    if touch:
        touch_event('touchEnd', end)
    else:
        page.mouse.up()
    if hold:
        return before
    page.wait_for_function('probeSample.stable!==undefined')
    sample = page.evaluate('probeSample')
    after = page.evaluate('probePosition()')
    assert sample['trusted'], 'The probe did not deliver trusted pointer input'
    assert (after == before) == cancel, (case, cancel, before['href'], after['href'])
    return sample


def compare_pixels(page, cdp, case, touch):
    drag(page, cdp, case, touch, hold=True)
    page.wait_for_function('probeSample.ready!==undefined && probeSample.settling')
    # Baseline might have replaced the back before starting its settle. Compare
    # what was actually visible under the fold while the pointer was held.
    page.evaluate('''()=>probeEffect.surface.upload(probeTextures.before,probeTextures.after,innerWidth,innerHeight)''')
    def snap(live):
        page.evaluate('live=>{probeEffect.livePage=live;probeEffect.update(.82);}', live)
        return Image.open(io.BytesIO(page.screenshot())).convert('L')
    preview, live = snap(-1), snap(1)
    w, h = live.size
    # Crop a strip on the revealed side away from the fold. Thresholds between
    # paper and ink forgive antialiasing and the shared cast shadow.
    x0, x1 = ((.06, .31) if case.endswith('back') else (.68, .94))
    crop = (round(w*x0), round(h*.07), round(w*x1), round(h*.90))
    a, b = [im.crop(crop) for im in (preview, live)]

    def line_centers(img):
        width, height = img.size
        data = list(img.get_flattened_data())
        counts = [sum(v < 110 for v in data[y*width:(y+1)*width]) for y in range(height)]
        threshold = max(4, max(counts)*.18)
        groups = []
        for y, count in enumerate(counts):
            if count < threshold:
                continue
            if not groups or y - groups[-1][-1] > 6:
                groups.append([])
            groups[-1].append(y)
        return [sum(y*counts[y] for y in group)/sum(counts[y] for y in group) for group in groups if len(group)>6]

    rows_a, rows_b = line_centers(a), line_centers(b)
    assert rows_a and rows_b, 'Handoff crop contains no visible lettering'
    same_lines = len(rows_a) == len(rows_b)
    displacement = max(abs(x-y) for x,y in zip(rows_a, rows_b)) if same_lines else None
    overlap = sum(x < 110 and y < 110 for x, y in zip(a.getdata(), b.getdata()))
    ink = max(sum(x < 110 for x in im.getdata()) for im in (a, b))
    page.evaluate('()=>{probeEffect.update(1);probeFinish();}')
    page.wait_for_function('probeSample.stable!==undefined')
    return {'case': case, 'previewLines': len(rows_a), 'liveLines': len(rows_b),
            'maxLineCenterShiftPx': round(displacement,2) if displacement is not None else None,
            'inkOverlap': round(overlap / ink,3)}


def summary(samples, cadence):
    def stats(values):
        ordered = sorted(values)
        return {'median': round(statistics.median(ordered), 1), 'p95': round(ordered[math.ceil(len(ordered)*.95)-1], 1)}
    intervals = [b-a for sample in samples for a, b in zip(sample['raf'], sample['raf'][1:])]
    return {'count': len(samples), 'releaseToMotionMs': stats([s['frames'][0]-s['release'] for s in samples]),
            'releaseToStableMs': stats([s['stable']-s['release'] for s in samples]),
            'releaseToDestinationMs': stats([s['ready']-s['release'] for s in samples]),
            'postReadyToMotionMs': stats([max(0,s['frames'][0]-s['ready']) for s in samples]),
            'frames': len(intervals), 'lateFramePercent': round(100*sum(i>cadence*1.5 for i in intervals)/len(intervals),1) if intervals else None,
            'releaseDecodes': sum(s['decodes'] for s in samples), 'releaseUploads': sum(s['uploads'] for s in samples)}


def local_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def wait_cdp(port):
    endpoint = f'http://127.0.0.1:{port}'
    for _ in range(60):
        try:
            with urlopen(endpoint + '/json/list', timeout=1) as response:
                if json.load(response):
                    return endpoint
        except OSError:
            pass
        time.sleep(.5)
    raise RuntimeError('The diagnostic WebView did not open its local DevTools socket')


def webview2_window(url, port, width, height, profile):
    import webview
    webview.settings['REMOTE_DEBUGGING_PORT'] = port
    webview.create_window('KMReader curl diagnostic', url, width=width, height=height)
    webview.start(gui='edgechromium', private_mode=False, storage_path=profile)


def command(*args, cwd=None):
    reply = subprocess.run([str(arg) for arg in args], cwd=cwd, check=True, capture_output=True, text=True)
    return reply.stdout.strip()


def android_apk(root, package):
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
    sdk_tools = sdk / 'build-tools' / '36.0.0'
    android_jar = sdk / 'platforms/android-36/android.jar'

    def executable(name, windows_ext='.exe'):
        return sdk_tools / (name + windows_ext if os.name == 'nt' else name)

    manifest = root / 'AndroidManifest.xml'
    manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}">
      <uses-permission android:name="android.permission.INTERNET"/>
      <application android:label="KMReader curl diagnostic" android:debuggable="true" android:usesCleartextTraffic="true">
        <activity android:name=".ProbeActivity" android:exported="true"/>
      </application></manifest>''', encoding='utf8')
    java = root / 'ProbeActivity.java'
    java.write_text(f'''package {package};
      public class ProbeActivity extends android.app.Activity {{
        public void onCreate(android.os.Bundle state) {{
          super.onCreate(state);
          getWindow().getDecorView().setSystemUiVisibility(5894);
          android.webkit.WebView.setWebContentsDebuggingEnabled(true);
          android.webkit.WebView web = new android.webkit.WebView(this);
          web.getSettings().setJavaScriptEnabled(true);
          web.getSettings().setUseWideViewPort(true);
          web.setWebViewClient(new android.webkit.WebViewClient());
          setContentView(web);
          web.loadUrl(getIntent().getStringExtra("origin"));
        }}
      }}''', encoding='utf8')
    classes, dex = root / 'classes', root / 'dex'
    classes.mkdir()
    dex.mkdir()
    command('javac', '-source', '8', '-target', '8', '-classpath', android_jar, '-d', classes, java)
    command(executable('d8', '.bat'), '--min-api', '28', '--lib', android_jar, '--output', dex, next(classes.rglob('*.class')))
    base, key, signed = [root / name for name in ('base.apk', 'fixture.jks', 'fixture.apk')]
    # Target 32 to retain the renderer's opt-in immersive window on Android 15.
    command(executable('aapt2'), 'link', '--manifest', manifest, '-I', android_jar, '--min-sdk-version', '28', '--target-sdk-version', '32', '-o', base)
    with zipfile.ZipFile(base, 'a', zipfile.ZIP_DEFLATED) as archive:
        archive.write(dex / 'classes.dex', 'classes.dex')
    command('keytool', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android', '-alias', 'fixture',
            '-keyalg', 'RSA', '-dname', 'CN=Generated diagnostic fixture', '-validity', '2')
    command(executable('apksigner', '.bat'), 'sign', '--ks', key, '--ks-pass', 'pass:android', '--out', signed, base)
    return signed


@contextmanager
def renderer(args, origin, port):
    if args.webview2:
        debug = local_port()
        # Edge's child processes can keep their profile locked briefly after the host exits.
        with tempfile.TemporaryDirectory(prefix='km-curl-webview-', ignore_cleanup_errors=True) as profile:
            host = subprocess.Popen([sys.executable, __file__, '--webview2-window', origin+'/A/reader/',
                                     str(debug), str(args.width + 30), str(args.height + 40), profile])
            try:
                yield wait_cdp(debug), 'WebView2 on Windows'
            finally:
                host.terminate()
                host.wait(timeout=10)
    elif args.android:
        if sum(line.split()[-1:] == ['device'] for line in command('adb', 'devices').splitlines()[1:]) != 1:
            raise RuntimeError('Expected one authorized Android device')
        emulator = command('adb', 'shell', 'getprop', 'ro.kernel.qemu') == '1'
        if emulator != (args.android == 'emulator'):
            raise RuntimeError('Connected Android renderer is not the selected device type')
        with tempfile.TemporaryDirectory(prefix='km-curl-android-') as scratch:
            package = f'dev.levalue.curlhandoff.p{os.getpid()}'
            apk = android_apk(Path(scratch), package)
            command('adb', 'install', apk)
            forward = None
            try:
                command('adb', 'reverse', f'tcp:{port}', f'tcp:{port}')
                command('adb', 'shell', 'am', 'start', '-W', '-n', f'{package}/.ProbeActivity', '--es', 'origin', origin+'/A/reader/')
                pid = command('adb', 'shell', 'pidof', package)
                assert pid.isdigit(), 'The diagnostic WebView process did not start'
                forward = command('adb', 'forward', 'tcp:0', f'localabstract:webview_devtools_remote_{pid}')
                yield wait_cdp(int(forward)), 'Android emulator' if emulator else 'Android physical device'
            finally:
                if forward:
                    command('adb', 'forward', '--remove', f'tcp:{forward}')
                command('adb', 'reverse', '--remove', f'tcp:{port}')
                command('adb', 'uninstall', package)
    else:
        yield args.cdp, args.engine


def run(args):
    baseline = subprocess.check_output(['git', 'show', f'{args.baseline}:assets/epub/reader.js'], cwd=ROOT)
    server = serve(baseline)
    origin = f'http://127.0.0.1:{server.server_port}'
    with renderer(args, origin, server.server_port) as (endpoint, engine), sync_playwright() as pw:
        if endpoint:
            browser = pw.chromium.connect_over_cdp(endpoint, no_defaults=True)
        else:
            browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
        page = (browser.contexts[0].pages[0] if endpoint else browser.new_page(viewport={'width': args.width, 'height': args.height},
                device_scale_factor=args.dpr, has_touch=args.touch, is_mobile=args.touch))
        cdp = page.context.new_cdp_session(page)
        cases = ['page-forward', 'chapter-forward', 'chapter-back', 'page-back']
        metrics = {label:{case:[] for case in cases} for label in 'AB'}
        pixels = {}
        if args.origin:
            origin = args.origin.format(port=server.server_port)
        page.set_default_timeout(12000)
        if endpoint:
            cdp.send('Emulation.setDeviceMetricsOverride', {'width': args.width, 'height': args.height,
                      'deviceScaleFactor': args.dpr, 'mobile': args.touch})
            if args.touch:
                cdp.send('Emulation.setTouchEmulationEnabled', {'enabled': True, 'maxTouchPoints': 1})
        cdp.send('Emulation.setEmulatedMedia', {'features':[{'name':'prefers-reduced-motion','value':'no-preference'}]})
        ages = {}
        for label in 'ABBA':
            configure(page, origin, label, args.columns)
            ages[label] = page.evaluate('''()=>new Promise(resolve=>{
              const frames=[];const tick=t=>{frames.push(t);if(frames.length<32)requestAnimationFrame(tick);
                else resolve(frames.slice(1).map((f,i)=>f-frames[i]));};requestAnimationFrame(tick);
            })''')
            for _ in range(args.repetitions):
                for case in cases:
                    sample = drag(page, cdp, case, args.touch)
                    assert sample['frames'] and 'ready' in sample, ('Missing measurement', case, label)
                    if label == 'B':
                        assert sample['decodes'] == sample['uploads'] == 0, ('Release rebuilt a texture', case)
                    metrics[label][case].append(sample)
        for label in 'AB':
            configure(page, origin, label, args.columns)
            drag(page, cdp, 'page-forward', args.touch, cancel=True)
            pixels[label] = [compare_pixels(page, cdp, case, args.touch) for case in ('chapter-forward','chapter-back')]
        result = {'engine': engine, 'browser': browser.version,
                  'viewport': page.evaluate('[innerWidth,innerHeight,devicePixelRatio]'),
                  'columns': args.columns, 'input': 'touch' if args.touch else 'mouse',
                  'cadenceMs': {label:round(statistics.median(ages[label]),2) for label in 'AB'},
                  'results': {label:{case:summary(samples, statistics.median(ages[label])) for case,samples in variants.items()}
                              for label,variants in metrics.items()}, 'handoffPixels': pixels, 'cancelRetainedCfi': True}
        print(json.dumps(result, indent=2), flush=True)
        if args.output:
            Path(args.output).write_text(json.dumps(result, indent=2), encoding='utf8')
        if not endpoint:
            browser.close()
    server.shutdown()


if __name__ == '__main__':
    if sys.argv[1:2] == ['--webview2-window']:
        url, port, width, height, profile = sys.argv[2:]
        webview2_window(url, int(port), int(width), int(height), profile)
        sys.exit()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='6bf5d31dd7035750276f114d1347ce7586ac365b')
    parser.add_argument('--width', type=int, default=393)
    parser.add_argument('--height', type=int, default=760)
    parser.add_argument('--dpr', type=float, default=1.5)
    parser.add_argument('--columns', type=int, choices=[1,2], default=1)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--touch', action='store_true')
    parser.add_argument('--engine', default='Chromium desktop')
    parser.add_argument('--cdp')
    parser.add_argument('--webview2', action='store_true')
    parser.add_argument('--android', choices=['emulator', 'physical'])
    parser.add_argument('--origin', help='Origin forwarded to the test renderer, with {port} substituted')
    parser.add_argument('--output')
    run(parser.parse_args())
