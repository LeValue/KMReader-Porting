import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/page_motion.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/epub_session.dart';
import 'package:kmreader/features/reader/page_transition.dart';
import 'package:kmreader/features/reader/reader_display.dart';
import 'package:kmreader/features/reader/reader_page.dart';
import 'package:kmreader/features/settings/settings_style.dart';
import 'package:kmreader/ui/reader_options.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

import 'widget_test.dart' show FixtureRepository;

void main() {
  setUpAll(Strings.initialize);
  test(
    'motion options survive reader copies and reject corrupt numeric values',
    () {
      final motion = PageMotion.fromJson({
        'animationDuration': 600,
        'followGesture': false,
        'pageTint': .18,
        'pageCornerRadius': 26,
      });
      final comic = ReaderPreferences.fromJson(motion.toJson())
          .copy(background: 'white');
      final epub = EpubPreferences.fromJson(motion.toJson());
      expect(comic.toJson(), containsPair('animationDuration', 600));
      expect(epub.toJson(), containsPair('followGesture', false));
      expect(comic.motion.tint, .18);
      expect(epub.motion.cornerRadius, 26);
      final corrupt = PageMotion.fromJson({
        'animationDuration': double.nan,
        'pageTint': double.infinity,
        'pageCornerRadius': -9,
      });
      expect(corrupt.duration, 380);
      expect(corrupt.tint, .1);
      expect(corrupt.cornerRadius, 0);
    },
  );
  for (final width in [320.0, 1200.0]) {
    testWidgets('settings titles and reader options remain bounded at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScaffold(
            title: 'EPUB Settings',
            body: ListView(children: const [Text('First option')]),
          ),
        ),
      );
      final appbar = tester.widget<AppBar>(find.byType(AppBar));
      expect((appbar.title as Text).data, 'EPUB Settings');
      expect(
        tester.getTopLeft(find.text('First option')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(AppBar)).dy),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 800),
              textScaler: const TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width.clamp(0, 760),
                  child: ReaderOptionsPanel(
                    title: 'Text Settings',
                    children: [
                      ReaderOptionGroup(
                        title: 'Page Turn',
                        children: [
                          ReaderOptionPicker(
                            title: 'Page Transition Style',
                            value: 'curl',
                            choices: const {
                              'curl': 'reader.page_transition.page_curl',
                            },
                            onChanged: (_) {},
                          ),
                          ReaderMotionOptions(
                            motion: const PageMotion(),
                            onChanged: (_) {},
                          ),
                        ],
                      ),
                      const SizedBox(height: 800),
                      const Text('Last option'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final titleTop = tester.getTopLeft(find.text('Text Settings'));
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Text Settings')), titleTop);
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'comic fullscreen button enters native fullscreen and Escape restores controls',
    (tester) async {
      final native = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ReaderDisplay.channel,
        (call) async {
          if (call.method == 'setFullscreen') {
            native.add(call.arguments as bool);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          ReaderDisplay.channel,
          null,
        ),
      );
      final directory = Directory.systemTemp.createTempSync('fullscreen-');
      final store = LocalStore(sqlite3.openInMemory())
        ..setSetting('showKeyboardHelpOverlay', false);
      const profile = ServerProfile(
        id: 'presentation',
        name: 'Fixture',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.apiKey,
      );
      final repository = FixtureRepository(
        profile: profile,
        store: store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: profile.authentication,
          credential: '',
        ),
      )..setOffline(true);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              repository: repository,
              book: Book({
                'id': 'p',
                'name': 'Comic',
                'media': {'pagesCount': 3},
              }),
            ),
          ),
        );
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(FixtureRepository.bytes),
            tester.element(find.byType(Scaffold)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Full Screen'));
        await tester.pumpAndSettle();
        expect(native.last, true);
        expect(find.byTooltip('Full Screen'), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(native.last, false);
        expect(find.byTooltip('Full Screen'), findsOneWidget);
        expect(find.byType(ReaderPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        repository.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  testWidgets(
    'rapid curl commands interrupt cosmetic duration instead of queuing waits',
    (tester) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.red, BlendMode.src);
      final picture = recorder.endRecording();
      final image = (await tester.runAsync(() => picture.toImage(80, 100)))!;
      picture.dispose();
      addTearDown(image.dispose);
      final key = GlobalKey<ReaderPageTransitionState>();
      var moves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageTransition(
            key: key,
            motion: const PageMotion(duration: 800),
            captureImage: () async => image.clone(),
            child: const ColoredBox(color: Colors.green),
          ),
        ),
      );
      final first = key.currentState!.turn('curl', 1, () async {
        moves++;
      });
      key.currentState!.turn('curl', 1, () async {
        moves++;
      });
      key.currentState!.turn('curl', 1, () async {
        moves++;
      });
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(moves, 3);
      await tester.pumpAndSettle();
      await first;
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    },
  );
  for (final commit in [false, true]) {
    testWidgets(
      'curl follows the drag and ${commit ? 'commits' : 'cancels'} on release',
      (tester) async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.red, BlendMode.src);
        final picture = recorder.endRecording();
        final image = (await tester.runAsync(() => picture.toImage(200, 300)))!;
        picture.dispose();
        addTearDown(image.dispose);
        final key = GlobalKey<ReaderPageTransitionState>();
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 200,
              height: 300,
              child: ReaderPageTransition(
                key: key,
                captureImage: () async => image.clone(),
                child: const ColoredBox(color: Colors.green),
              ),
            ),
          ),
        );
        var previews = 0, commits = 0, cancels = 0;
        final drag = key.currentState!.drag(
          reverse: false,
          width: 200,
          preview: (delta) async {
            expectSync(delta, 1);
            previews++;
            return true;
          },
          finish: (delta, accepted) async {
            if (accepted) {
              commits++;
            } else {
              cancels++;
            }
          },
        );
        drag.update(
          DragUpdateDetails(
            globalPosition: Offset.zero,
            delta: Offset(commit ? -90 : -25, 0),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(previews, 1);
        expect(commits, 0);
        final painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<PageTurnPainter>()
            .single;
        expect(painter.progress, closeTo(commit ? .45 : .125, .001));
        drag.end(DragEndDetails());
        await tester.pumpAndSettle();
        expect(commits, commit ? 1 : 0);
        expect(cancels, commit ? 0 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
    );
  }
}
