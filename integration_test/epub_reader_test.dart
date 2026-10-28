import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native WebView paginates, persists CFI and reflows without moving saved progress',
    (tester) async {
      await Strings.initialize();
      final directory = await Directory.systemTemp.createTemp(
        'kmreader-native-epub-',
      );
      final store = LocalStore(sqlite3.openInMemory());
      const profile = ServerProfile(
        id: 'native-epub',
        name: 'Native fixture',
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
        'id': 'native-book',
        'name': 'EPUB native verification',
        'media': {'mediaProfile': 'EPUB', 'pagesCount': 100},
      });
      final file = fixture(directory);
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 180; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (ready()) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('Native EPUB did not reach its expected state.');
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: ReaderDisplay(
              child: BrowserEpubReader(
                file: file,
                repository: repository,
                book: book,
              ),
            ),
          ),
        );
        await waitFor(
          () =>
              find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              find.byTooltip('Next Page').evaluate().isNotEmpty,
        );
        expect(find.textContaining('Install Microsoft Edge'), findsNothing);
        await tester.tap(find.byTooltip('Next Page'));
        await waitFor(
          () =>
              text(object(store.cached(profile.id, 'epub:${book.id}'))['cfi'])
                  .startsWith('epubcfi('),
        );
        final saved = object(store.cached(profile.id, 'epub:${book.id}'));
        expect(repository.pendingCount, 1);
        await tester.tap(find.byType(PopupMenuButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Text Settings').last);
        await tester.pumpAndSettle();
        final slider = find.byType(Slider).first;
        await tester.drag(slider, const Offset(80, 0));
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pump();
        expect(
          object(store.cached(profile.id, 'epub:${book.id}'))['cfi'],
          saved['cfi'],
        );
        expect(
          object(store.cached(profile.id, 'epub:${book.id}'))['fontSize'],
          isNot(19),
        );
        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
        if (Platform.isAndroid) {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
          await binding.takeScreenshot('epub-native-paged');
        }
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        repository.dispose();
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
