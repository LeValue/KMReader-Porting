import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/reader_page.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'widget_test.dart' show FixtureRepository;

import 'package:kmreader/features/reader/reader_viewport.dart';

void main() {
  for (final rtl in [false, true]) {
    testWidgets('single-finger paging, late pinch and zoomed pan; RTL=$rtl', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pages = PageController();
      final zoom = TransformationController();
      var initialPage = 0, current = 0, builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderViewport(
              controller: zoom,
              onContact: () => initialPage = (pages.page ?? 0).round(),
              onPinch: () => pages.jumpToPage(initialPage),
              startScroll: (details) => pages.position.drag(details, () {}),
              child: PageView.builder(
                controller: pages,
                reverse: rtl,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 4,
                onPageChanged: (page) => current = page,
                itemBuilder: (context, page) {
                  builds++;
                  return ColoredBox(
                    color: Colors.primaries[page],
                    child: Center(child: Text('Page $page')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(ReaderViewport),
        Offset(rtl ? 280 : -280, 0),
      );
      await tester.pumpAndSettle();
      expect(current, 1);
      expect(pages.page, closeTo(1, .001));

      // The first finger starts a real turn before the second arrives.
      final first = await tester.startGesture(
        const Offset(330, 300),
        pointer: 1,
      );
      await first.moveBy(Offset(rtl ? 90 : -90, 0));
      await tester.pump();
      expect((pages.page! - 1).abs(), greaterThan(.05));
      final second = await tester.startGesture(
        const Offset(260, 360),
        pointer: 2,
      );
      await tester.pump();
      expect(
        pages.page,
        closeTo(1, .001),
        reason: 'A pinch must roll back the unfinished page turn',
      );
      await first.moveTo(const Offset(100, 260));
      await second.moveTo(const Offset(320, 420));
      await tester.pump();
      await first.moveTo(const Offset(60, 220));
      await second.moveTo(const Offset(350, 460));
      await tester.pump();
      expect(zoom.value.getMaxScaleOnAxis(), greaterThan(1.1));
      await second.up();
      await first.moveBy(Offset(rtl ? 160 : -160, 0));
      await first.up();
      await tester.pumpAndSettle();
      expect(
        current,
        1,
        reason: 'The remaining finger must continue panning rather than change pages',
      );
      expect(pages.page, closeTo(1, .001));

      final built = builds;
      final scale = zoom.value.getMaxScaleOnAxis();
      await tester.drag(find.byType(ReaderViewport), const Offset(-45, 30));
      await tester.pumpAndSettle();
      expect(pages.page, closeTo(1, .001));
      expect(zoom.value.getMaxScaleOnAxis(), closeTo(scale, .001));
      expect(
        builds,
        built,
        reason: 'Panning must reuse the rendered page subtree',
      );

      await tester.tapAt(const Offset(200, 350));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(200, 350));
      await tester.pumpAndSettle();
      expect(zoom.value.isIdentity(), isTrue);
      await tester.drag(
        find.byType(ReaderViewport),
        Offset(rtl ? 280 : -280, 0),
      );
      await tester.pumpAndSettle();
      expect(current, 2, reason: 'Paging resumes after zoom reset');
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 300),
          scrollDelta: Offset(0, -100),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(zoom.value.getMaxScaleOnAxis(), greaterThan(1));
      expect(
        current,
        2,
        reason: 'Desktop mouse-wheel zoom must not become paging',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      pages.dispose();
      zoom.dispose();
    });
  }

  testWidgets(
    'comic viewport fills the screen; pinch does not record a page turn',
    (tester) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('reader-touch-');
      final store = LocalStore(sqlite3.openInMemory());
      const profile = ServerProfile(
        id: 'touch',
        name: 'Fixture',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.apiKey,
      );
      final repo = FixtureRepository(
        profile: profile,
        store: store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: profile.authentication,
          credential: '',
        ),
      )..setOffline(true);
      addTearDown(() {
        repo.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      });
      final book = Book({
        'id': 'touch',
        'name': 'Touch fixture',
        'media': {'pagesCount': 3},
        'readProgress': {'page': 1},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 700),
              padding: EdgeInsets.only(top: 30, bottom: 24),
              viewPadding: EdgeInsets.only(top: 30, bottom: 24),
            ),
            child: ReaderPage(repository: repo, book: book),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          ResizeImage.resizeIfNeeded(
            400,
            null,
            MemoryImage(FixtureRepository.bytes),
          ),
          tester.element(find.byType(Scaffold)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ReaderViewport)), const Size(400, 700));
      expect(
        tester.getTopLeft(find.byTooltip('Close')).dy,
        greaterThanOrEqualTo(30),
      );
      expect(repo.pendingCount, 0);
      final first = await tester.startGesture(
        const Offset(330, 300),
        pointer: 1,
      );
      await first.moveBy(const Offset(-30, 0));
      await tester.pump();
      await first.moveBy(const Offset(-220, 0));
      await tester.pump();
      expect(find.text('2 / 3'), findsOneWidget);
      expect(
        repo.pendingCount,
        0,
        reason: 'Crossing the midpoint during a drag must not commit progress',
      );
      final second = await tester.startGesture(
        const Offset(270, 350),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(const Offset(20, 170));
      await second.moveTo(const Offset(390, 500));
      await tester.pump();
      await second.up();
      await first.up();
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);
      expect(repo.pendingCount, 0);
      final viewport = tester.widget<ReaderViewport>(
        find.byType(ReaderViewport),
      );
      viewport.controller.value = Matrix4.identity();
      await tester.drag(find.byType(ReaderViewport), const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      expect(repo.pendingCount, 1);
      expect(repo.overlay(book).page, 2);
      await tester.tap(find.byTooltip('Full Screen'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close'), findsNothing);
      expect(tester.getSize(find.byType(ReaderViewport)), const Size(400, 700));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets('vertical dragging survives recycling the touched page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('reader-vertical-');
    final store = LocalStore(sqlite3.openInMemory());
    const profile = ServerProfile(
      id: 'vertical',
      name: 'Fixture',
      url: 'https://example.invalid',
      email: '',
      authentication: Authentication.apiKey,
    );
    final repo = FixtureRepository(
      profile: profile,
      store: store,
      directory: directory,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: '',
      ),
    )..setOffline(true);
    addTearDown(() {
      repo.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    });
    store.cache(
      profile.id,
      'reader:v',
      const ReaderPreferences(mode: ReadingMode.webtoon).toJson(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          repository: repo,
          book: Book({
            'id': 'v',
            'media': {'pagesCount': 3},
            'readProgress': {'page': 1},
          }),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        ResizeImage.resizeIfNeeded(
          400,
          null,
          MemoryImage(FixtureRepository.bytes),
        ),
        tester.element(find.byType(Scaffold)),
      ),
    );
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final first = await tester.startGesture(const Offset(200, 300));
    await first.moveBy(const Offset(0, -30));
    await tester.pump();
    await first.moveBy(const Offset(0, -650));
    await tester.pump();
    final offset = position.pixels;
    expect(offset, greaterThan(600));
    await first.moveBy(const Offset(0, -150));
    await tester.pump();
    expect(position.pixels, greaterThan(offset + 100));
    await first.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
    'hidden bars retain notch insets for title, buttons and reader sheets',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReaderDisplay.channel, (call) async {
        return {
          'left': 0,
          'top': 108,
          'right': 0,
          'bottom': 72,
          'cutoutTop': 108,
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(ReaderDisplay.channel, null),
      );
      Widget reader(Size size, {bool extend = false}) => MaterialApp(
        home: MediaQuery(
          // Reproduces Android clearing Flutter's padding in immersive mode.
          data: MediaQueryData(size: size, devicePixelRatio: 3),
          child: ReaderDisplay(
            child: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: ReaderPageSurface(
                      extendIntoCutout: extend,
                      child: const ColoredBox(
                        key: ValueKey('page'),
                        color: Colors.black,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: ReaderSafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          IconButton(
                            key: const ValueKey('close'),
                            onPressed: () {},
                            icon: const Icon(Icons.close),
                          ),
                          const Expanded(
                            child: Text('Comic title', key: ValueKey('title')),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: ReaderSafeArea(
                      top: false,
                      child: SizedBox(key: ValueKey('footer'), height: 48),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(reader(const Size(800, 600)));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('page'))),
        const Rect.fromLTWH(0, 36, 800, 564),
      );
      expect(tester.getTopLeft(find.byKey(const ValueKey('close'))).dy, 36);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('title'))).dy,
        greaterThanOrEqualTo(36),
      );
      expect(
        tester.getBottomRight(find.byKey(const ValueKey('footer'))).dy,
        576,
      );

      tester.binding.channelBuffers.push(
        ReaderDisplay.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('readerInsets', {
            'left': 132,
            'top': 0,
            'right': 24,
            'bottom': 36,
            'cutoutLeft': 132,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('close'))),
        const Offset(44, 0),
      );
      expect(
        tester.getBottomRight(find.byKey(const ValueKey('footer'))),
        const Offset(792, 588),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('page'))),
        const Rect.fromLTWH(44, 0, 756, 600),
      );
      await tester.pumpWidget(reader(const Size(800, 600), extend: true));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('page'))),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('close'))).dx,
        44,
        reason: 'Opting into cutout content must never move controls under hardware',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'document-reader app bars receive native safe insets with hidden system bars',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        ReaderDisplay.channel,
        (_) async => {
          'left': 0,
          'top': 48,
          'right': 0,
          'bottom': 24,
          'cutoutTop': 48,
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(ReaderDisplay.channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(800, 600)),
            child: ReaderDisplay(
              child: Scaffold(
                appBar: AppBar(title: const Text('EPUB / PDF title')),
                body: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('EPUB / PDF title')).dy,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android reader display restores system UI after the last reader closes',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ReaderDisplay.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          ReaderDisplay.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const ReaderDisplay(child: ReaderDisplay(child: SizedBox())),
      );
      await tester.pump();
      expect(calls.where((call) => call.arguments == true).length, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.map((call) => call.arguments), [true, false]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
