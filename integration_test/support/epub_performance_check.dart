import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_reader.dart';
import 'package:kmreader/features/reader/epub_session.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/ui/theme.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test/support/epub_fixture.dart';

void verifyNativeEpubPerformance() {
  testWidgets('native default EPUB survives rapid turns and renderer interruption', (
    tester,
  ) async {
    await Strings.initialize();
    final directory = await Directory.systemTemp.createTemp('epub-stress-');
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'epub-stress',
      name: 'Fixture',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    final repository = Repository(
      profile: profile,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: '',
      ),
      store: store,
      directory: directory,
    )..setOffline(true);
    final book = Book({
      'id': 'stress',
      'name': 'Long chapter',
      'media': {'mediaProfile': 'EPUB'},
    });
    Future<void> waitFor(bool Function() ready) async {
      for (var i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (ready()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail(
        'Default EPUB did not settle: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' | ')}',
      );
    }

    InAppWebViewController? controller() {
      // Public diagnostic getter avoids replacing the production native view.
      final dynamic state = tester.state(find.byType(BrowserEpubReader));
      return state.browserController as InAppWebViewController?;
    }

    Future<dynamic> js(String source) async {
      final result = await controller()!
          .callAsyncJavaScript(functionBody: source)
          .timeout(const Duration(seconds: 20));
      expect(result?.error, isNull);
      return result?.value;
    }

    Future<dynamic> jsWhilePresenting(String source) async {
      final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
      final policy = binding.framePolicy;
      // Functional animation delivery needs the platform texture consumer to
      // honor native frame requests between explicit test pumps. This scoped
      // policy is not used to measure production idle frames or device FPS.
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      try {
        var finished = false;
        final reply = controller()!
            .callAsyncJavaScript(functionBody: source)
            .timeout(const Duration(seconds: 60))
            .whenComplete(() => finished = true);
        final deadline = Stopwatch()..start();
        while (!finished && deadline.elapsed < const Duration(seconds: 65)) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        final result = await reply;
        expect(result?.error, isNull);
        return result?.value;
      } finally {
        binding.framePolicy = policy;
      }
    }

    Future<void> visibleText() async {
      // Native bounds, DOM repagination and raster delivery are independent.
      // Wait for the actual surface size and layout instead of assuming a
      // fixed 300ms is sufficient on a software-rendered emulator.
      var settled = false;
      for (var attempt = 0; attempt < 60; attempt++) {
        final expected = tester.getSize(find.byType(InAppWebView));
        final geometry = object(
          await js(
            'return {width:innerWidth,height:innerHeight,ready:reader.layoutReady()};',
          ),
        );
        if (geometry['ready'] == true &&
            ((geometry['width'] as num).toDouble() - expected.width).abs() <
                2 &&
            ((geometry['height'] as num).toDouble() - expected.height).abs() <
                2) {
          settled = true;
          break;
        }
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        settled,
        true,
        reason: 'Native WebView bounds and EPUB layout must settle',
      );
      await js('await reader.whenIdle();return true;');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (final view in tester.binding.renderViews) {
        view.markNeedsPaint();
      }
      await tester.pump(const Duration(milliseconds: 100));
      ui.Image image;
      if (Platform.isAndroid) {
        Uint8List? bytes;
        for (var attempt = 0; attempt < 5; attempt++) {
          try {
            bytes = await ReaderDisplay.channel.invokeMethod<Uint8List>(
              'captureScreenshot',
            );
            break;
          } on PlatformException catch (error) {
            final noFrameYet =
                error.code == 'capture_failed' &&
                    error.message == 'PixelCopy failed: 3' ||
                error.code == 'Could not copy the pixels' &&
                    error.message == 'result was 3';
            if (!noFrameYet || attempt == 4) rethrow;
            for (final view in tester.binding.renderViews) {
              view.markNeedsPaint();
            }
            await tester.pump(const Duration(milliseconds: 250));
          }
        }
        expect(bytes, isNotEmpty);
        final codec = await ui.instantiateImageCodec(bytes!);
        image = (await codec.getNextFrame()).image;
        codec.dispose();
      } else {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find
              .ancestor(
                of: find.byType(InAppWebView),
                matching: find.byType(RepaintBoundary),
              )
              .first,
        );
        image = await boundary.toImage();
      }
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var dark = 0, light = 0;
        // Ignore window controls/bars; the center must contain actual glyphs.
        for (var y = image.height ~/ 4; y < image.height * 3 ~/ 4; y++) {
          for (var x = image.width ~/ 4; x < image.width * 3 ~/ 4; x++) {
            final index = (y * image.width + x) * 4;
            if (data.getUint8(index) < 120 &&
                data.getUint8(index + 1) < 120 &&
                data.getUint8(index + 2) < 120) {
              dark++;
            }
            if (data.getUint8(index) > 180 &&
                data.getUint8(index + 1) > 180 &&
                data.getUint8(index + 2) > 160) {
              light++;
            }
          }
        }
        expect(
          dark,
          greaterThan(150),
          reason: 'The native reader surface must render text, not only report a DOM locator',
        );
        expect(
          light,
          greaterThan(150),
          reason: 'A missing black texture must not count as rendered glyphs',
        );
      } finally {
        image.dispose();
      }
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: ReaderDisplay(
            child: BrowserEpubReader(
              file: fixture(directory, paragraphCount: 1400),
              repository: repository,
              book: book,
            ),
          ),
        ),
      );
      await waitFor(
        () =>
            find.byType(CircularProgressIndicator).evaluate().isEmpty &&
            controller() != null,
      );
      final view = tester.widget<InAppWebView>(find.byType(InAppWebView));
      if (Platform.isAndroid) {
        final rendering = object(
          await ReaderDisplay.channel.invokeMapMethod<String, dynamic>(
            'getWebViewRenderingStats',
          ),
        );
        expect(rendering['hardwareAccelerated'], true);
        expect(
          rendering['layerType'],
          0,
          reason: 'Keep the default hardware-accelerated view, without a forced offscreen layer',
        );
        expect(
          (rendering['parents'] as List).any(
            (p) => p.toString().contains('PlatformViewWrapper'),
          ),
          true,
          reason: 'The EPUB must use the real texture composition path',
        );
        debugPrint('Native Android WebView composition: $rendering');
      }

      final initial = await js('return reader.position().start.cfi;');
      await js(
        '''window.turnArguments=[]; window.completedTurns=0; const turn=reader.turn;
        reader.turn=async value=>{turnArguments.push(value); await turn(value); completedTurns++; return true;}; return true;''',
      );
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byTooltip('Next Page'));
        await tester.pump(const Duration(milliseconds: 10));
      }
      await waitFor(
        () =>
            object(store.cached(profile.id, 'epub:${book.id}'))['cfi'] != null,
      );
      expect(await js('return reader.position().start.cfi;'), isNot(initial));
      for (var i = 0; i < 100; i++) {
        if (await js('return completedTurns;') == 6) break;
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await js('return completedTurns;'), 6);
      expect(await js('return turnArguments.length;'), 6);
      expect(
        await js(
          'return turnArguments.every(v=>!Object.hasOwn(v,"snapshot"));',
        ),
        true,
      );
      expect(
        identical(view, tester.widget<InAppWebView>(find.byType(InAppWebView))),
        true,
        reason: 'Locator updates must retain the native WebView widget',
      );
      // Chrome overlays must retain both the native surface and its bounds.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      final viewportBeforeChrome = await js('return [innerWidth,innerHeight];');
      final retainedController = controller();
      var readingAnchor = await js('return reader.position().start.cfi;');
      for (var i = 0; i < 2; i++) {
        await js(
          "const frame=document.querySelector('#viewer iframe'),doc=frame.contentDocument,b=frame.getBoundingClientRect();doc.body.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:innerWidth/2-b.left,clientY:innerHeight/2-b.top}));return true;",
        );
        if (Platform.isWindows) {
          await tester.tapAt(
            tester.getCenter(find.byType(InAppWebView)),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(find.byTooltip('Next Page'), findsOneWidget);
          expect(
            await ReaderDisplay.channel.invokeMethod<bool>('getFullscreen'),
            false,
          );
          expect(
            await js(
              "return document.querySelector('#viewer iframe').contentDocument.getSelection().isCollapsed;",
            ),
            true,
          );
          final beforeArrow = await js('return reader.position().start.cfi;');
          final beforeCount = (await js('return completedTurns;') as num)
              .toInt();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          for (var attempt = 0; attempt < 30; attempt++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (await js('return reader.position().start.cfi;') !=
                beforeArrow) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
            await js('return reader.position().start.cfi;'),
            isNot(beforeArrow),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          for (var attempt = 0; attempt < 50; attempt++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (await js('return completedTurns;') == beforeCount + 2) break;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(await js('return completedTurns;'), beforeCount + 2);
          await js('await reader.whenIdle();return true;');
          readingAnchor = await js('return reader.position().start.cfi;');
        } else {
          await waitFor(() => find.byTooltip('Next Page').evaluate().isEmpty);
        }
        expect(identical(controller(), retainedController), true);
        expect(
          await js('return [innerWidth,innerHeight];'),
          viewportBeforeChrome,
        );
        await visibleText();
        await js(
          "document.querySelector('#viewer iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true;",
        );
        await waitFor(() => find.byTooltip('Next Page').evaluate().isNotEmpty);
        if (Platform.isWindows) {
          await tester.tap(find.byTooltip('Full Screen'));
        } else {
          await tester.tap(find.byType(PopupMenuButton<String>).first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Full Screen').last);
        }
        await waitFor(() => find.byTooltip('Next Page').evaluate().isEmpty);
        if (Platform.isWindows) {
          expect(
            await ReaderDisplay.channel.invokeMethod<bool>('getFullscreen'),
            true,
          );
        }
        expect(identical(controller(), retainedController), true);
        await visibleText();
        await js(
          "document.querySelector('#viewer iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true;",
        );
        await waitFor(() => find.byTooltip('Next Page').evaluate().isNotEmpty);
        if (Platform.isWindows) {
          expect(
            await ReaderDisplay.channel.invokeMethod<bool>('getFullscreen'),
            false,
          );
        }
        await visibleText();
        expect(await js('return reader.position().start.cfi;'), readingAnchor);
      }
      // Exercise the real WebView GPU/texture path, not only headless Chrome.
      expect(
        await js("""
          // Emulator accessibility disables animation. Exercise actual GPU
          // pixels in this scoped branch, then restore the media query.
          window.nativeMedia=window.matchMedia;
          window.matchMedia=query=>query.includes('prefers-reduced-motion')?{matches:false}:nativeMedia.call(window,query);
          window.nativeStart=KMReaderSheetEffect.prototype.start;
          window.nativeAnimate=KMReaderSheetEffect.prototype.animateTo;
          KMReaderSheetEffect.prototype.start=async function(move){window.nativeCurl=this;return nativeStart.call(this,move);};
          KMReaderSheetEffect.prototype.animateTo=function(){return new Promise(()=>{});};
          await reader.turn({delta:1,style:'curl'});
          if(!window.nativeCurl)throw Error('GPU effect did not start: supported='+KMReaderSheetEffect.supported('curl')+', reduced='+matchMedia('(prefers-reduced-motion: reduce)').matches);
          if(!nativeCurl.surface||!document.getElementById('page-curl-surface'))throw Error('Native GPU curl unavailable');
          nativeCurl.update(.5,{x:innerWidth*.5,y:innerHeight*.25});
          return nativeCurl.surface.canvas.width>=innerWidth && nativeCurl.surface.shadowTargets.length===2 && nativeCurl.surface.gl.getError()===0;
        """),
        true,
      );
      await visibleText();
      // Observe automatic playback before the synchronous GPU readback probes
      // below can saturate a software emulator's render queue.
      await jsWhilePresenting("""
          nativeCurl.stop();KMReaderSheetEffect.prototype.start=nativeStart;
          KMReaderSheetEffect.prototype.animateTo=nativeAnimate;
          const automatic=new KMReaderSheetEffect('slide',1,{},.5,false,false);
          if(!await automatic.start(async()=>{}))throw Error('Native automatic slide unavailable');
          // Use the supported maximum duration so the software renderer has
          // more than one frame to expose the compositor's intermediate state.
          const started=performance.now(),flight=automatic.animateTo(1,900,{automatic:true});
          const initialCompositor=!!automatic.compositor;
          // Observe delivered render frames instead of assuming a 90ms wall
          // timer runs before a software-rendered emulator finishes the turn.
          const samples=[];
          for(let frame=0;frame<120;frame++){
            await new Promise(requestAnimationFrame);samples.push(automatic.progress);
            if(automatic.progress>0&&automatic.progress<1)break;
            if(automatic.stopped||automatic.progress>=1)break;
          }
          if(!samples.some(p=>p>0&&p<1))throw Error('Native automatic slide skipped its intermediate frames: '+JSON.stringify({samples,stopped:automatic.stopped,compositor:!!automatic.compositor}));
          await flight;automatic.stop();window.matchMedia=nativeMedia;
          await reader.previous();return true;
      """);
      await js("""
          // Check both receiving planes on actual native GPU pixels. Removing
          // the flat front's receiver in the control must recreate the seam.
          const receiverProbe=(() => {
  const surface=nativeCurl.surface,g=surface.gl,stock=document.createElement('canvas');
  stock.width=innerWidth;stock.height=innerHeight;
  const c=stock.getContext('2d');c.fillStyle='#fff';c.fillRect(0,0,stock.width,stock.height);
  surface.upload(stock,stock,innerWidth,innerHeight);
  const width=surface.canvas.width,height=surface.canvas.height;
  const black=g.createTexture();g.activeTexture(g.TEXTURE3);g.bindTexture(g.TEXTURE_2D,black);
  g.texImage2D(g.TEXTURE_2D,0,g.RGBA,1,1,0,g.RGBA,g.UNSIGNED_BYTE,new Uint8Array([0,0,0,255]));
  g.texParameteri(g.TEXTURE_2D,g.TEXTURE_MIN_FILTER,g.NEAREST);
  const bind=(program,buffer)=>{g.useProgram(program.p);g.bindBuffer(g.ARRAY_BUFFER,buffer);g.enableVertexAttribArray(program.a);g.vertexAttribPointer(program.a,2,g.FLOAT,false,0,0);};
  const sample=()=>{const out=new Uint8Array(4);g.readPixels(Math.floor(width/2)+2,Math.floor(height/2),1,1,g.RGBA,g.UNSIGNED_BYTE,out);return out[0];};
  const results=[];
  for(const p of [.5,.55,.6,.65]){
    surface.render(p,true,1,0,.5);
    const draw=receiver=>{
      g.disable(g.DEPTH_TEST);bind(surface.background,surface.quad);g.drawArrays(g.TRIANGLE_STRIP,0,4);
      const background=sample();
      g.clear(g.DEPTH_BUFFER_BIT);g.enable(g.DEPTH_TEST);g.enable(g.CULL_FACE);g.cullFace(g.BACK);
      bind(surface.sheet,surface.mesh);g.uniform1i(surface.sheet.u.castShadow,receiver);
      g.bindBuffer(g.ELEMENT_ARRAY_BUFFER,surface.indices);g.drawElements(g.TRIANGLES,surface.count,g.UNSIGNED_SHORT,0);
      const front=sample();g.disable(g.CULL_FACE);g.disable(g.DEPTH_TEST);return {background,front};
    };
    const fixed=draw(2),old=draw(3);
    // Read the broad shadow edge on a plain receiving surface, excluding the
    // folded sheet so paper geometry cannot hide the gradient's extent.
    bind(surface.background,surface.quad);g.drawArrays(g.TRIANGLE_STRIP,0,4);
    const row=new Uint8Array(width*4);g.readPixels(0,Math.floor(height/2),width,1,g.RGBA,g.UNSIGNED_BYTE,row);
    const shade=Array.from({length:width},(_,x)=>255-row[x*4]),peak=Math.max(...shade);
    const start=shade.findIndex(v=>v>=peak*.1),end=shade.findIndex(v=>v>=peak*.8);
    let run=0,plateau=0;
    for(let x=start+1;x<=end;x++){run=shade[x]===shade[x-1]?run+1:0;plateau=Math.max(plateau,run);}
    results.push({p,fixed,old,peak,plateau,edgePixels:end-start,edgeWidth:(end-start)*innerWidth/width});
  }
  g.useProgram(surface.sheet.p);g.uniform1i(surface.sheet.u.castShadow,2);g.deleteTexture(black);
  surface.render(0,true,1,0,.5);return {results,error:g.getError()};
}
)();
          if(receiverProbe.error!==0||!receiverProbe.results.every(s=>
            Math.abs(s.fixed.background-s.fixed.front)<=2 &&
            s.old.front-s.old.background>60 && s.peak>=75 && s.edgeWidth>=10+innerWidth*.01 &&
            s.plateau<=Math.max(2,s.edgePixels*.08)))
            throw Error('Native curl shadow receiver: '+JSON.stringify(receiverProbe));
  {const surface=nativeCurl.surface,g=surface.gl;
  const originalUpload=g.texImage2D;let uploads=0;
  g.texImage2D=function(...args){uploads++;return originalUpload.apply(this,args);};
  try {
    const pages=Array.from({length:4},(_,i)=>{const page=document.createElement('canvas');page.width=64;page.height=64;const c=page.getContext('2d');c.fillStyle=['red','green','blue','white'][i];c.fillRect(0,0,64,64);return page;});
    const counts=[];
    for(const [front,back] of [[pages[0],pages[1]],[pages[1],pages[2]],[pages[2],null],[pages[2],pages[3]]]){
      uploads=0;surface.upload(front,back,innerWidth,innerHeight);counts.push(uploads);
    }
    if(counts.join(',')!=='2,1,0,1')throw Error('Sequential page textures uploaded again: '+counts);
    surface.render(0,true,1,0,.5);
    const pixel=new Uint8Array(4);g.readPixels(0,0,1,1,g.RGBA,g.UNSIGNED_BYTE,pixel);
    if(pixel[2]<250||pixel[0]>2)throw Error('Texture rotation selected the wrong front: '+pixel);
    // Exercise the complete production start, not only the texture cache API.
    // Its initial frame reads the front only; mirroring it into the back would
    // upload that same page again immediately before loading the new back.
    const savedEffect=window.effect,savedNative=window.nativeCurl,queue=[pages[3],pages[0]];
    const real=new KMReaderSheetEffect('curl',1,{},.5,false,true,async()=>queue.shift());
    uploads=0;
    try {
      if(!await real.start(async()=>{}))throw Error('Real curl start unavailable');
      if(uploads!==1)throw Error('Real curl start reuploaded a retained front: '+uploads);
      real.update(0);g.readPixels(0,0,1,1,g.RGBA,g.UNSIGNED_BYTE,pixel);
      if(pixel[0]<250||pixel[1]<250||pixel[2]<250)throw Error('Real curl start selected the wrong front');
      real.update(1);g.readPixels(0,0,1,1,g.RGBA,g.UNSIGNED_BYTE,pixel);
      if(pixel[0]<250||pixel[1]>2||pixel[2]>2)throw Error('Real curl start selected the wrong back');
    } finally {real.stop();window.effect=savedEffect;window.nativeCurl=savedNative;}

  } finally {g.texImage2D=originalUpload;}
}
          return true;
        """);
      // The action must retain its selected passage even if native focus
      // clears the DOM selection while the toolbar popup is open.
      final selected = await js("""
          const frame=document.querySelector('#viewer iframe'),doc=frame.contentDocument,b=frame.getBoundingClientRect();
          const paragraph=[...doc.querySelectorAll('p')].find(p=>[...p.getClientRects()].some(r=>r.right+b.left>0&&r.left+b.left<innerWidth&&r.bottom+b.top>0&&r.top+b.top<innerHeight));
          window.selectionParagraph=paragraph;doc.getSelection().selectAllChildren(paragraph);return paragraph.textContent;
        """);
      final dynamic selectionState = tester.state(
        find.byType(BrowserEpubReader),
      );
      await waitFor(() => selectionState.selectedText == selected);
      if (Platform.isWindows) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await waitFor(() => selectionState.selectedText == '');
        expect(
          find.byType(BrowserEpubReader),
          findsOneWidget,
          reason: 'Escape clears text selection before leaving a book',
        );
        await js(
          'selectionParagraph.ownerDocument.getSelection().selectAllChildren(selectionParagraph);return true;',
        );
        await waitFor(() => selectionState.selectedText == selected);
      }
      // Reveal/reset idle chrome immediately before opening the action.
      // Hovering the book's top edge preserves the selected passage; an
      // Escape key would clear it. Earlier GPU work may consume five seconds.
      // A live desktop already owns mouse device 1. Keep this test mouse
      // separate, and use the same device for hover, press and release.
      final pointer = TestGesture(
        dispatcher: tester.sendEventToBinding,
        pointer: 424242,
        device: 424242,
        kind: PointerDeviceKind.mouse,
      );
      try {
        await pointer.addPointer();
        await pointer.moveTo(
          tester.getTopLeft(find.byType(BrowserEpubReader)) +
              const Offset(8, 8),
        );
        await waitFor(
          () => find.byType(PopupMenuButton<String>).evaluate().isNotEmpty,
        );
        await pointer.down(
          tester.getCenter(find.byType(PopupMenuButton<String>).first),
        );
        await pointer.up();
      } finally {
        await pointer.removePointer();
      }
      await tester.pumpAndSettle();
      expect(find.text('Translate Selected Text'), findsOneWidget);
      await js(
        "document.querySelector('#viewer iframe').contentDocument.getSelection().removeAllRanges();return true;",
      );
      await waitFor(() => selectionState.selectedText == '');
      await tester.tap(find.text('Translate Selected Text'));
      await tester.pumpAndSettle();
      expect(find.text(selected as String), findsOneWidget);
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      await visibleText();
      final result = object(
        await js('''const times=[];
        for(let i=0;i<48;i++) { const old=reader.position().start.cfi, at=performance.now();
          await reader.turn({delta:1,style:'slide'}); times.push(performance.now()-at);
          if(reader.position().start.cfi===old) throw new Error('Page did not advance '+i);
        } times.sort((a,b)=>a-b); return {median:times[24],max:times[47]};'''),
      );
      debugPrint(
        'Native EPUB command latency (debug engine, not device FPS): $result',
      );
      await visibleText();
      {
        final channel = MethodChannel(
          'com.pichillilorenzo/custom_platform_view_${controller()!.getViewId()}',
        );
        Future<Json> captureStats() async => object(
          await channel.invokeMapMethod<String, dynamic>('getRenderingStats'),
        );
        final preferences = jsonEncode(const EpubPreferences().toJson());
        await js(
          'await reader.preferences({...$preferences,flow:"scrolled"});await reader.whenIdle();return true;',
        );
        await visibleText();
        final beforeCapture = Platform.isWindows ? await captureStats() : null;
        var finished = false;
        // Collect the raw result here: the js() assertion must not run in
        // parallel with a guarded tester.pump(). Assert after pumping finishes.
        final scrolling = controller()!
            .callAsyncJavaScript(
              functionBody: """
            const viewport=document.querySelector('.epub-container');
            const start=performance.now(),base=viewport.scrollTop,positions=[];
            await new Promise(resolve=>{
              const frame=now=>{
                viewport.scrollTop=base+30*(positions.length%5);
                positions.push(viewport.scrollTop);
                if(positions.length<12)requestAnimationFrame(frame);else resolve();
              };requestAnimationFrame(frame);
            });
            return {frames:positions.length,elapsed:performance.now()-start,
              distance:Math.max(...positions)-Math.min(...positions)};
          """,
            )
            .timeout(const Duration(seconds: 20))
            .whenComplete(() => finished = true);
        // Keep Flutter presenting while the real WebView scrolls, as it does
        // in the application. The test binding otherwise only draws on pump.
        for (var frame = 0; frame < 300 && !finished; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        expect(finished, true, reason: 'Native scrolling must complete');
        final scrollReply = await scrolling;
        expect(scrollReply?.error, isNull);
        final scrollingResult = object(scrollReply?.value);
        await visibleText();
        expect(scrollingResult['distance'], greaterThan(5));
        if (Platform.isWindows) {
          final afterCapture = await captureStats();
          debugPrint(
            'Native Windows vertical scrolling, debug CI renderer (not physical display FPS): $scrollingResult; capture before=$beforeCapture after=$afterCapture',
          );

          expect(afterCapture['freeThreaded'], true);
          if (afterCapture['captureIntervalSupported'] == true) {
            expect(afterCapture['captureIntervalResult'], 0);
            expect(
              afterCapture['captureInterval100ns'],
              10000,
              reason: 'Read back the live positive 1ms capture interval; zero alone can retain Windows default pacing.',
            );
          }
          expect(afterCapture['uiThreadCaptures'], 0);
          expect(
            afterCapture['captures'],
            greaterThan(beforeCapture!['captures'] as num),
          );
          expect(
            afterCapture['gpuCopies'],
            greaterThan(beforeCapture['gpuCopies'] as num),
          );
          expect(
            afterCapture['gpuCopies'],
            lessThanOrEqualTo(afterCapture['captures'] as num),
          );
        }
        await js(
          'await reader.preferences($preferences);await reader.whenIdle();return true;',
        );
        await visibleText();
      }
      if (Platform.isWindows) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await tester.pump();
        final saved = object(
          store.cached(profile.id, 'epub:${book.id}'),
        )['cfi'];
        final oldController = controller();
        // Exercise a real WebView2 renderer exit, not a simulated Dart event.
        unawaited(
          oldController!
              .callDevToolsProtocolMethod(methodName: 'Page.crash')
              .timeout(const Duration(seconds: 3))
              .then<void>((_) {}, onError: (Object _) {}),
        );
        await waitFor(
          () =>
              controller() != null &&
              !identical(oldController, controller()) &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
        expect(await js('return reader.position().start.cfi;'), saved);
        await visibleText();
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
      repository.dispose();
      store.close();
      await directory.delete(recursive: true);
    }
  });
}
