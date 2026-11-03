// A normal application binding: integration_test's fullyLive binding keeps
// requesting frames and therefore cannot measure the production idle cost.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_reader.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:kmreader/ui/theme.dart';
import 'package:sqlite3/sqlite3.dart';

import '../test/support/epub_fixture.dart';

final _navigation = GlobalKey<NavigatorState>();
final _host = GlobalKey<_ProbeHostState>();
var _reader = GlobalKey();
final _frames = <ui.FrameTiming>[];
final _report = <String, dynamic>{
  'schema': 1,
  'source': Platform.environment['GITHUB_SHA'],
  'runtimeSource': const String.fromEnvironment(
    'KMREADER_PROFILE_RUNTIME_SOURCE',
  ),
  'binding': 'WidgetsFlutterBinding',
  'phases': <String, dynamic>{},
};

class _ProbeHost extends StatefulWidget {
  const _ProbeHost({super.key});
  @override
  State<_ProbeHost> createState() => _ProbeHostState();
}

class _ProbeHostState extends State<_ProbeHost> {
  Widget child = const Scaffold(
    body: Center(child: Text('Reader diagnostics')),
  );
  void show(Widget value) => setState(() => child = value);
  @override
  Widget build(BuildContext context) => child;
}

T? _widget<T extends Widget>(bool Function(T) predicate) {
  T? found;
  void visit(Element element) {
    if (found != null) return;
    final widget = element.widget;
    if (widget is T && predicate(widget)) {
      found = widget;
    } else {
      element.visitChildElements(visit);
    }
  }

  final context = _navigation.currentContext;
  if (context is Element) visit(context);
  return found;
}

InAppWebViewController? get _browser =>
    (_reader.currentState as dynamic)?.browserController
        as InAppWebViewController?;

Future<dynamic> _js(String body) async {
  final reply = await _browser!
      .callAsyncJavaScript(functionBody: body)
      .timeout(const Duration(seconds: 60));
  if (reply?.error != null) throw StateError('${reply!.error}');
  return reply?.value;
}

Future<void> _until(FutureOr<bool> Function() ready) async {
  final clock = Stopwatch()..start();
  while (!await ready()) {
    if (clock.elapsed > const Duration(seconds: 60)) {
      throw StateError('Reader diagnostic condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<Map<String, dynamic>> _capture() async =>
    (await MethodChannel(
      'com.pichillilorenzo/custom_platform_view_${_browser!.getViewId()}',
    ).invokeMapMethod<String, dynamic>('getRenderingStats')) ??
    {};

Future<dynamic> _metrics() async {
  if (_browser == null) return null;
  const names = {
    'Timestamp',
    'TaskDuration',
    'ScriptDuration',
    'LayoutDuration',
    'RecalcStyleDuration',
    'LayoutCount',
    'RecalcStyleCount',
    'JSHeapUsedSize',
    'JSHeapTotalSize',
    'Nodes',
    'Documents',
    'Frames',
    'JSEventListeners',
  };
  final result = await _browser!.callDevToolsProtocolMethod(
    methodName: 'Performance.getMetrics',
  );
  final values = result?['metrics'] as List? ?? [];
  return {
    for (final value in values)
      if (names.contains(value['name'])) value['name']: value['value'],
  };
}

Future<void> _save() async {
  final output = Platform.environment['KMREADER_RESPONSE_OUTPUT'];
  if (output == null) throw StateError('Missing diagnostic output path.');
  await File(output).writeAsString(
    const JsonEncoder.withIndent('  ').convert(_report),
    flush: true,
  );
}

Future<void> _phase(
  String name,
  Future<dynamic> Function() action, {
  bool browser = true,
  bool settleBefore = true,
}) async {
  if (settleBefore) {
    await Future<void>.delayed(const Duration(milliseconds: 1100));
  }
  final before = browser ? await _capture() : null;
  final metricsBefore = browser ? await _metrics() : null;
  final start = DateTime.now().microsecondsSinceEpoch;
  final value = await action();
  final finish = DateTime.now().microsecondsSinceEpoch;
  final after = browser ? await _capture() : null;
  final metricsAfter = browser ? await _metrics() : null;
  await Future<void>.delayed(const Duration(milliseconds: 1100));
  final frames = _frames.where((frame) {
    final time = frame.timestampInMicroseconds(
      ui.FramePhase.rasterFinishWallTime,
    );
    return time >= start && time <= finish;
  }).toList();
  (_report['phases'] as Map)[name] = {
    'startEpochMs': start / 1000,
    'finishEpochMs': finish / 1000,
    'elapsedMs': (finish - start) / 1000,
    'action': value,
    'captureBefore': before,
    'captureAfter': after,
    'browserBefore': metricsBefore,
    'browserAfter': metricsAfter,
    'appRssBytes': ProcessInfo.currentRss,
    'appMaxRssBytes': ProcessInfo.maxRss,
    'flutterFrames': frames.length,
    'buildMs': frames
        .map((f) => f.buildDuration.inMicroseconds / 1000)
        .toList(),
    'rasterMs': frames
        .map((f) => f.rasterDuration.inMicroseconds / 1000)
        .toList(),
  };
  _frames.clear();
  await _save();
}

Future<dynamic> _turn() async {
  if (_widget<IconButton>((w) => w.tooltip == 'Next Page') == null) {
    await _revealControls();
  }
  await _js('window.kmLastTurn=null;return true;');
  final button = _widget<IconButton>((w) => w.tooltip == 'Next Page');
  if (button?.onPressed == null) {
    throw StateError('Actual reader next button unavailable.');
  }
  final inputEpochMs = DateTime.now().microsecondsSinceEpoch / 1000;
  button!.onPressed!();
  final value = await _js('''
    const deadline=performance.now()+10000;
    while(!window.kmLastTurn){
      if(performance.now()>deadline)throw Error('Reader input did not reach browser');
      await new Promise(r=>setTimeout(r,5));
    }
    const sample=kmLastTurn;await sample.navigation;
    if(['slide','curl'].includes(sample.style)&&!sample.flight)throw Error('Animation path unavailable');
    if(sample.flight)await sample.flight;
    return {...sample,navigation:undefined,flight:undefined};
  ''');
  return {'inputEpochMs': inputEpochMs, 'browser': value};
}

Future<void> _revealControls() async {
  // Escape reveals the real reader controls. The root route cannot be popped.
  await _js(
    "document.querySelector('#viewer iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true;",
  );
  await _until(() => _widget<PopupMenuButton<String>>((w) => true) != null);
}

const _instrument = r'''
  window.kmSamples={decode:[],serialize:[],clone:[],mapping:[],longTasks:[]};
  const stamp=()=>Date.now(),max=256;
  const record=(name,value)=>{const a=kmSamples[name];if(a.length<max)a.push(value);};
  try{new PerformanceObserver(list=>{
    for(const e of list.getEntries())record('longTasks',{start:e.startTime,ms:e.duration});
  }).observe({type:'longtask',buffered:true});}catch(_){}
  const decode=Image.prototype.decode;
  Image.prototype.decode=function(...args){
    const at=performance.now(),epoch=stamp(),length=this.src.length;
    return decode.apply(this,args).finally(()=>record('decode',{epoch,ms:performance.now()-at,length}));
  };
  const serialize=XMLSerializer.prototype.serializeToString;
  XMLSerializer.prototype.serializeToString=function(...args){
    const at=performance.now(),value=serialize.apply(this,args);
    record('serialize',{epoch:stamp(),ms:performance.now()-at,length:value.length});return value;
  };
  for(const frame of document.querySelectorAll('#viewer iframe')){
    const prototype=frame.contentWindow.Node.prototype,clone=prototype.cloneNode;
    prototype.cloneNode=function(...args){
      const at=performance.now(),value=clone.apply(this,args);
      if(this.nodeType===1&&this.tagName==='HTML')record('clone',{epoch:stamp(),ms:performance.now()-at});
      return value;
    };
  }
  if(ePub.Rendition){
    const current=ePub.Rendition.prototype.currentLocation;
    ePub.Rendition.prototype.currentLocation=function(...args){
      const at=performance.now(),value=current.apply(this,args);
      record('mapping',{epoch:stamp(),ms:performance.now()-at});return value;
    };
  }
  const start=KMReaderSheetEffect.prototype.start,animate=KMReaderSheetEffect.prototype.animateTo,update=KMReaderSheetEffect.prototype.update;
  KMReaderSheetEffect.prototype.start=async function(...args){
    this.kmSample=window.kmLastTurn;const at=performance.now();
    const ready=await start.apply(this,args);
    if(this.kmSample)this.kmSample.prepareMs=performance.now()-at;
    return ready;
  };
  KMReaderSheetEffect.prototype.animateTo=function(...args){
    const sample=this.kmSample;if(sample)sample.animationReadyEpochMs=stamp();
    const flight=animate.apply(this,args);if(sample)sample.flight=flight;return flight;
  };
  KMReaderSheetEffect.prototype.update=function(value,...args){
    const sample=this.kmSample;
    if(this.style==='curl'&&sample&&value>0&&sample.firstProgressEpochMs===undefined)sample.firstProgressEpochMs=stamp();
    return update.call(this,value,...args);
  };
  const turn=reader.turn;
  reader.turn=function(value){
    const sample=window.kmLastTurn={style:value.style,receivedEpochMs:stamp()};
    const before=reader.position().start.cfi;
    sample.navigation=turn(value).then(result=>{
      sample.commandResolvedEpochMs=stamp();sample.changed=reader.position().start.cfi!==before;
      if(!sample.changed)throw Error('Reader page did not advance');return result;
    });return sample.navigation;
  };return true;
''';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
  FlutterError.onError = (details) {
    (_report['frameworkErrors'] ??= <String>[] as dynamic).add(
      details.exceptionAsString(),
    );
  };
  await Strings.initialize();
  final directory = await Directory.systemTemp.createTemp('epub-response-');
  final store = LocalStore(sqlite3.openInMemory());
  const profile = ServerProfile(
    id: 'response',
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
  try {
    final external = Platform.environment['KMREADER_PROFILE_EPUB'];
    final publication = external == null
        ? fixture(directory, paragraphCount: 1400)
        : File(external);
    final bytes = await publication.readAsBytes();
    _report['publication'] = {
      'kind': external == null ? 'generated' : 'external',
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
    runApp(
      MaterialApp(
        navigatorKey: _navigation,
        theme: appTheme(Brightness.light),
        // Exercise the real animation path even on hosted Windows machines
        // with accessibility animation effects disabled. This affects only
        // the probe, never the installed application or operating system.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: false),
          child: child!,
        ),
        home: _ProbeHost(key: _host),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    await _phase('flutterIdle', () async {
      await Future<void>.delayed(const Duration(seconds: 3));
      return true;
    }, browser: false);
    for (final style in ['none', 'slide', 'curl', 'vertical']) {
      store.setSetting('epubDefault', {
        'transition': style == 'vertical' ? 'none' : style,
        if (style == 'vertical') 'flow': 'scrolled',
      });
      _reader = GlobalKey();
      final opening = Stopwatch()..start();
      _host.currentState!.show(
        ReaderDisplay(
          keepAwake: true,
          child: BrowserEpubReader(
            key: _reader,
            file: publication,
            repository: repository,
            book: Book({
              'id': style,
              'name': 'Reader diagnostics',
              'media': {'mediaProfile': 'EPUB'},
            }),
          ),
        ),
      );
      await _until(() => _browser != null);
      await _browser!.callDevToolsProtocolMethod(
        methodName: 'Performance.enable',
      );
      await _until(() async {
        try {
          return await _js(
                'return typeof reader!=="undefined"&&reader.layoutReady()&&!!reader.position()?.start?.cfi;',
              ) ==
              true;
        } catch (_) {
          return false;
        }
      });
      opening.stop();
      (_report['openingMs'] ??= <String, dynamic>{} as dynamic)[style] =
          opening.elapsedMicroseconds / 1000;
      (_report['systemReducedMotion'] ??=
          <String, dynamic>{} as dynamic)[style] = await _js(
        'return matchMedia("(prefers-reduced-motion: reduce)").matches;',
      );
      await _browser!.callDevToolsProtocolMethod(
        methodName: 'Emulation.setEmulatedMedia',
        parameters: {
          'features': [
            {'name': 'prefers-reduced-motion', 'value': 'no-preference'},
          ],
        },
      );
      await _js(_instrument);
      (_report['browser'] ??=
          <String, dynamic>{} as dynamic)[style] = await _js(
        'return {width:innerWidth,height:innerHeight,dpr:devicePixelRatio,reducedMotion:matchMedia("(prefers-reduced-motion: reduce)").matches,timeOrigin:performance.timeOrigin};',
      );
      // No warm-up turn or idle delay before the first input.
      await _phase('${style}FirstTurn', _turn, settleBefore: false);
      await _phase('${style}FollowingTurns', () async {
        final turns = <dynamic>[];
        for (var i = 0; i < 3; i++) {
          turns.add(await _turn());
        }
        return turns;
      });
      await _phase('${style}Idle', () async {
        await Future<void>.delayed(const Duration(seconds: 3));
        return true;
      });
      // Location mapping must also stay cheap deep inside a long chapter.
      // Move the actual scrollport, then measure real inputs after settling.
      await _js('''
        const viewport=document.querySelector('.epub-container');
        document.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:1}));
        if('$style'==='vertical')viewport.scrollTop=Math.floor((viewport.scrollHeight-viewport.clientHeight)/2/viewport.clientHeight)*viewport.clientHeight;
        else viewport.scrollLeft=(getComputedStyle(viewport).direction==='rtl'?-1:1)*Math.floor((viewport.scrollWidth-viewport.clientWidth)/2/viewport.clientWidth)*viewport.clientWidth;
        await new Promise(resolve=>setTimeout(resolve,400));
        await reader.whenIdle();return true;
      ''');
      await _phase('${style}MiddleTurns', () async {
        final turns = <dynamic>[];
        for (var i = 0; i < 3; i++) {
          turns.add(await _turn());
        }
        return turns;
      });
      if (style == 'vertical') {
        await _phase('verticalWheel', () async {
          final before = await _js('return reader.position()?.start?.cfi;');
          for (var i = 0; i < 20; i++) {
            await _browser!.callDevToolsProtocolMethod(
              methodName: 'Input.dispatchMouseEvent',
              parameters: {
                'type': 'mouseWheel',
                'x': 400,
                'y': 300,
                'deltaX': 0,
                'deltaY': 100,
              },
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          await Future<void>.delayed(const Duration(milliseconds: 450));
          final after = await _js('return reader.position()?.start?.cfi;');
          if (before == after) {
            throw StateError('Wheel did not move the publication.');
          }
          return true;
        });
      }
      await _phase('${style}Settings', () async {
        final times = <double>[];
        for (var i = 0; i < 3; i++) {
          await _revealControls();
          final clock = Stopwatch()..start();
          _widget<PopupMenuButton<String>>((w) => true)!
              .onSelected!('settings');
          await _until(() => _widget<BottomSheet>((w) => true) != null);
          await WidgetsBinding.instance.endOfFrame;
          times.add(clock.elapsedMicroseconds / 1000);
          await Future<void>.delayed(const Duration(milliseconds: 350));
          _navigation.currentState!.pop();
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        return times;
      });
      (_report['browserSamples'] ??= <String, dynamic>{} as dynamic)[style] =
          await _js('return kmSamples;');
      _host.currentState!.show(
        const Scaffold(body: Center(child: Text('Preparing next reader'))),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if ((_report['frameworkErrors'] as List? ?? []).isNotEmpty) {
      throw StateError('Framework errors during probe.');
    }
    _report['success'] = true;
  } catch (error, stack) {
    _report['success'] = false;
    _report['error'] = '$error';
    _report['stack'] = '$stack';
  } finally {
    _host.currentState?.show(const SizedBox.shrink());
    await Future<void>.delayed(const Duration(seconds: 1));
    await _save();
    repository.dispose();
    store.close();
    await directory.delete(recursive: true);
    _report['complete'] = true;
    await _save();
  }
  // The launcher owns this process, as in the native startup smoke test.
  // Stay alive after sealing the report so it can stop this diagnostic tree
  // without involving desktop engine shutdown in the performance measurement.
}
