import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/page_parts.dart';
import 'package:kmreader/features/reader/reader_page.dart';
import 'package:kmreader/features/reader/tap_zones.dart';

import 'widget_test.dart' show FixtureRepository;

class _WideRepository extends FixtureRepository {
  _WideRepository({
    required super.profile,
    required super.store,
    required super.directory,
    required super.api,
    required this.wideBytes,
  });
  final Uint8List wideBytes;
  @override
  Future<Uint8List> page(String id, int page) async => wideBytes;
  @override
  Future<Uint8List> prefetchPage(String id, int page) async => wideBytes;
}

void main() {
  test(
    'tap zone layouts and inversion match upstream grid and T-split rules',
    () {
      const previous = TapAction.previous,
          controls = TapAction.controls,
          next = TapAction.next;
      const grids = {
        'none': [
          controls,
          controls,
          controls,
          controls,
          controls,
          controls,
          controls,
          controls,
          controls,
        ],
        'default': [
          previous,
          controls,
          next,
          previous,
          controls,
          next,
          previous,
          controls,
          next,
        ],
        'edge': [next, next, next, next, controls, next, next, previous, next],
        'kindle': [
          controls,
          controls,
          controls,
          previous,
          next,
          next,
          previous,
          next,
          next,
        ],
        'lShape': [
          previous,
          previous,
          previous,
          previous,
          controls,
          next,
          next,
          next,
          next,
        ],
      };
      for (final grid in grids.entries) {
        for (var row = 0; row < 3; row++) {
          for (var column = 0; column < 3; column++) {
            final x = (column + .5) / 3, y = (row + .5) / 3;
            expect(
              tapAction(x, y, ReaderPreferences(tapMode: grid.key)),
              grid.value[row * 3 + column],
            );
            expect(
              tapAction(
                x,
                y,
                ReaderPreferences(
                  tapMode: grid.key,
                  direction: ReadingDirection.rtl,
                ),
              ),
              grid.value[row * 3 + 2 - column],
            );
          }
        }
      }
      expect(
        tapAction(.1, .12, const ReaderPreferences(tapMode: 'tSplit')),
        controls,
      );
      expect(
        tapAction(.1, .13, const ReaderPreferences(tapMode: 'tSplit')),
        previous,
      );
      expect(
        tapAction(
          .1,
          .13,
          const ReaderPreferences(tapMode: 'tSplit', tapInversion: 'inverted'),
        ),
        next,
      );
      expect(preloadWindow('lowMemory'), (before: 1, after: 3));
      expect(preloadWindow('balanced'), (before: 3, after: 5));
      expect(preloadWindow('fastPageTurns'), (before: 5, after: 7));
    },
  );
  test('wide pages split in explicit or automatic order; unknown sizes remain full', () {
    final sizes = [
      {'number': 1, 'width': 2000, 'height': 1000},
      {'number': 2, 'width': 800, 'height': 1200},
    ];
    List<(int, int)> parts(ReaderPreferences settings) =>
        pageParts(3, sizes, settings).map((p) => (p.page, p.half)).toList();
    expect(parts(const ReaderPreferences(splitWide: 'auto')), [
      (1, 1),
      (1, 2),
      (2, 0),
      (3, 0),
    ]);
    expect(
      parts(
        const ReaderPreferences(
          splitWide: 'auto',
          direction: ReadingDirection.rtl,
        ),
      ),
      [(1, 2), (1, 1), (2, 0), (3, 0)],
    );
    expect(
      parts(
        const ReaderPreferences(
          splitWide: 'ltr',
          direction: ReadingDirection.rtl,
        ),
      ),
      [(1, 1), (1, 2), (2, 0), (3, 0)],
    );
    expect(
      parts(
        const ReaderPreferences(splitWide: 'auto', mode: ReadingMode.vertical),
      ),
      [(1, 0), (2, 0), (3, 0)],
    );
    final settings = const ReaderPreferences(
      splitWide: 'rtl',
      tapMode: 'kindle',
      preload: 'fastPageTurns',
      animate: false,
    );
    expect(
      ReaderPreferences.fromJson(settings.toJson()).toJson(),
      settings.toJson(),
    );
  });
  for (final incognito in [false, true]) {
    testWidgets(
      'wide-page completion waits for the second half, incognito=$incognito',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync('reader-parts-');
        final store = LocalStore(sqlite3.openInMemory());
        const profile = ServerProfile(
          id: 'split',
          name: 'Test',
          url: 'https://example.invalid',
          email: '',
          authentication: Authentication.apiKey,
        );
        final wideBytes = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 100, 100),
            Paint()..color = Colors.red,
          );
          canvas.drawRect(
            const Rect.fromLTWH(100, 0, 100, 100),
            Paint()..color = Colors.blue,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(200, 100);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          return data!.buffer.asUint8List();
        });
        final repository = _WideRepository(
          wideBytes: wideBytes!,
          profile: profile,
          store: store,
          directory: directory,
          api: KomgaApi(
            Uri.parse(profile.url),
            authentication: Authentication.apiKey,
            credential: '',
          ),
        )..setOffline(true);
        addTearDown(() {
          repository.dispose();
          store.close();
          directory.deleteSync(recursive: true);
        });
        store.cache(
          profile.id,
          'reader:b',
          const ReaderPreferences(splitWide: 'auto', animate: false).toJson(),
        );
        store.cache(
          profile.id,
          jsonEncode(['/api/v1/books/b/pages', 'GET', null, null]),
          [
            {'number': 1, 'width': 2000, 'height': 1000},
          ],
        );
        final book = Book({
          'id': 'b',
          'name': 'Wide page',
          'media': {'pagesCount': 1},
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: key,
              child: ReaderPage(
                repository: repository,
                book: book,
                incognito: incognito,
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => precacheImage(
            ResizeImage.resizeIfNeeded(1600, null, MemoryImage(wideBytes)),
            tester.element(find.byType(Scaffold)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(repository.pendingCount, 0);
        expect(find.textContaining('· Left'), findsOneWidget);
        expect(find.text('Next Book'), findsNothing);
        Future<List<int>> pixel(int x, int y) async =>
            (await tester.runAsync(() async {
              final boundary =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final bytes = data!.buffer.asUint8List();
              final value = bytes.sublist(
                (y * image.width + x) * 4,
                (y * image.width + x) * 4 + 4,
              );
              image.dispose();
              return value;
            }))!;
        expect(
          await pixel(150, 300),
          [244, 67, 54, 255],
          reason:
              'The left half must be centered and fill its own aspect ratio.',
        );
        await tester.tap(find.byIcon(CupertinoIcons.chevron_right));
        await tester.pumpAndSettle();
        expect(find.textContaining('· Right'), findsOneWidget);
        expect(find.text('Next Book'), findsOneWidget);
        expect(await pixel(650, 300), [
          33,
          150,
          243,
          255,
        ], reason: 'The right half must contain the right image pixels.');
        expect(repository.pendingCount, incognito ? 0 : 1);
        if (!incognito) expect(repository.overlay(book).completed, isTrue);
        expect(store.cached(profile.id, 'readerPart:b') != null, !incognito);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
