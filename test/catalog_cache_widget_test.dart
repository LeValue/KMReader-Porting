import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/catalog_page.dart';

import 'widget_test.dart' show FixtureRepository;

void main() {
  testWidgets(
    'background revalidation keeps loaded pages and the scrolled position',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'kmreader-pagination-',
      );
      final store = LocalStore(sqlite3.openInMemory());
      var fresh = false;
      var requests = 0;
      const profile = ServerProfile(
        id: 'pagination',
        name: 'Test',
        url: 'https://example.invalid',
        email: '',
        authentication: Authentication.password,
      );
      final repository = FixtureRepository(
        profile: profile,
        store: store,
        directory: directory,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: Authentication.password,
          credential: '',
          client: MockClient((request) async {
            requests++;
            final page = int.parse(request.url.queryParameters['page']!);
            return http.Response(
              jsonEncode({
                'content': List.generate(
                  40,
                  (i) => {
                    'id': '${page * 40 + i}',
                    'name': '${fresh ? 'Fresh' : 'Old'} book ${page * 40 + i}',
                    'media': {'pagesCount': 10},
                  },
                ),
                'last': page == 1,
                'totalElements': 80,
              }),
              200,
            );
          }),
        ),
      );
      addTearDown(() {
        repository.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogPageView(repository: repository, kind: 'books'),
          ),
        ),
      );
      for (final width in [128, 256, 512, 1024]) {
        await tester.runAsync(
          () => precacheImage(
            ResizeImage.resizeIfNeeded(
              width,
              null,
              MemoryImage(FixtureRepository.bytes),
            ),
            tester.element(find.byType(Scaffold)),
          ),
        );
      }
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(requests, 2);
      final offset = scrollable.position.pixels;
      final extent = scrollable.position.maxScrollExtent;
      fresh = true;
      repository.refreshContent();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, offset);
      expect(scrollable.position.maxScrollExtent, extent);
      expect(find.textContaining('Fresh book '), findsWidgets);
      expect(requests, 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
