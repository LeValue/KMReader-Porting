import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/catalog_page.dart';
import 'package:sqlite3/sqlite3.dart';

class _Repository extends Repository {
  _Repository({
    required super.profile,
    required super.store,
    required super.directory,
    required super.api,
  });

  @override
  Future<Uint8List> image(String path, {bool refresh = false}) async =>
      File('test/fixtures/page.png').readAsBytesSync();
}

void main() {
  late LocalStore store;
  late Directory directory;
  late Repository repository;
  late bool failSecondPage;
  late List<int> selectedPages;

  setUp(() {
    store = LocalStore(sqlite3.openInMemory());
    directory = Directory.systemTemp.createTempSync('catalog-parity-');
    failSecondPage = false;
    selectedPages = [];
    const profile = ServerProfile(
      id: 'catalog',
      name: 'Catalog',
      url: 'https://catalog.invalid',
      email: 'reader@example.invalid',
      authentication: Authentication.apiKey,
    );
    repository = _Repository(
      profile: profile,
      directory: directory,
      store: store,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: 'fixture',
        client: MockClient((request) async {
          final params = request.url.queryParameters;
          final bulk = params['size'] == '200';
          final page = int.tryParse(params['page'] ?? '') ?? 0;
          if (bulk) selectedPages.add(page);
          if (bulk && page == 1 && failSecondPage) {
            return http.Response('', 400);
          }
          final titles = [
            if (page == 0) 'First',
            if (bulk) page == 0 ? 'Second' : 'Third',
          ];
          return http.Response(
            jsonEncode({
              'content': [
                for (final title in titles)
                  {
                    'id': title,
                    'name': title,
                    'metadata': {'title': title},
                  },
              ],
              'last': !bulk || page == 1,
              'totalElements': bulk ? 3 : 1,
            }),
            200,
          );
        }),
      ),
    );
  });

  tearDown(() {
    repository.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });

  Widget view({ValueChanged<List<CatalogItem>>? picked}) => MaterialApp(
    home: Scaffold(
      body: CatalogPageView(
        repository: repository,
        kind: 'books',
        preferenceScope: 'test',
        onPicked: picked,
      ),
    ),
  );

  testWidgets('catalog sorting and layout survive reopening the view', (
    tester,
  ) async {
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Recently Added'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Layout'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'First'), findsOneWidget);
    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckedPopupMenuItem<String>>(
            find.widgetWithText(CheckedPopupMenuItem<String>, 'Recently Added'),
          )
          .checked,
      isTrue,
    );
  });

  testWidgets(
    'bulk selection commits all pages only after the full query succeeds',
    (tester) async {
      List<CatalogItem>? picked;
      await tester.pumpWidget(view(picked: (value) => picked = value));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      expect(find.text('1 Selected'), findsOneWidget);
      Future<void> selectAll() async {
        await tester.tap(find.byTooltip('Select All'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Select All Results'));
        await tester.pumpAndSettle();
      }

      failSecondPage = true;
      await selectAll();
      expect(find.text('1 Selected'), findsOneWidget);
      failSecondPage = false;
      await selectAll();
      expect(find.text('3 Selected'), findsOneWidget);
      expect(selectedPages, containsAllInOrder([0, 1, 1]));
      await tester.tap(find.byTooltip('Done'));
      expect(picked?.map((value) => value.id), ['First', 'Second', 'Third']);
    },
  );
}
