import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/file_export.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/reader/page_image_view.dart';
import 'package:kmreader/features/reader/reader_page.dart';
import 'package:kmreader/features/reader/reader_viewport.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

import 'widget_test.dart' show FixtureRepository;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(Strings.initialize);
  const selector = MethodChannel('plugins.flutter.io/file_selector');
  for (final outcome in ['saved', 'cancelled', 'failed']) {
    test(
      'page export re-encodes PNG and removes private files when $outcome',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'page-export-test-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final destination = File('${directory.path}/exported.png');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(selector, (call) async {
          expect(call.method, 'getSavePath');
          final args = object(call.arguments);
          expect(args['suggestedName'], 'kmreader-page-2.png');
          expect(
            object((args['acceptedTypeGroups'] as List).single)['extensions'],
            ['png'],
          );
          expect(directory.listSync().whereType<Directory>(), hasLength(1));
          if (outcome == 'failed') throw PlatformException(code: 'fixture');
          return outcome == 'cancelled' ? null : destination.path;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(selector, null));
        final exporting = saveEncodedPageImage(
          FixtureRepository.bytes,
          directory,
          page: 2,
        );
        if (outcome == 'failed') {
          await expectLater(exporting, throwsA(isA<PlatformException>()));
        } else {
          expect(await exporting, outcome == 'saved');
        }
        expect(directory.listSync().whereType<Directory>(), isEmpty);
        expect(destination.existsSync(), outcome == 'saved');
        if (destination.existsSync()) {
          expect(destination.readAsBytesSync().take(8), [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
          ]);
          final codec = await ui.instantiateImageCodec(
            destination.readAsBytesSync(),
          );
          final image = (await codec.getNextFrame()).image;
          expect(image.width, greaterThan(0));
          image.dispose();
          codec.dispose();
        }
      },
    );
  }
  testWidgets(
    'solo action selects either spread page and preserves reader position',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'solo-reader-test-',
      );
      final store = LocalStore(sqlite3.openInMemory());
      const profile = ServerProfile(
        id: 'solo',
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
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            repository: repo,
            book: Book({
              'id': 'solo',
              'media': {'pagesCount': 4},
            }),
            incognito: true,
            initialPreferences: const ReaderPreferences(
              pageLayout: 'dual-forced',
              spread: true,
              soloCover: false,
              useSeriesDirection: false,
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (final width in [500, 1000]) {
          await precacheImage(
            ResizeImage(MemoryImage(FixtureRepository.bytes), width: width),
            tester.element(find.byType(ReaderPage)),
          );
        }
      });
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      await tester.longPress(find.byType(ReaderViewport).first);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      expect(find.text('Show Page 1 Solo'), findsOneWidget);
      expect(find.text('Show Page 2 Solo'), findsOneWidget);
      await tester.tap(find.text('Show Page 2 Solo'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      expect(tester.widget<PageImageView>(find.byType(PageImageView)).page, 2);
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(FixtureRepository.bytes),
          tester.element(find.byType(PageImageView)),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      expect(find.byType(PageImageView), findsNothing);
      expect(find.text('1 / 4'), findsOneWidget);
      expect(repo.pendingCount, 0);
      expect(store.cached(profile.id, 'reader:solo'), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(repo.stopDownloadWork);
    },
  );
}
