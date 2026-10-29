import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/repository.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/features/catalog/komf_page.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(Strings.initialize);
  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'Komf identifies a oneshot, ignores stale search and monitors completion at $width px',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync('komf-ui-');
        final store = LocalStore(sqlite3.openInMemory());
        final oldSearch = Completer<http.Response>();
        final submitted = <Json>[];
        final repository = Repository(
          profile: const ServerProfile(
            id: 's',
            name: 'Fixture',
            url: 'https://example.invalid',
            email: '',
            authentication: Authentication.apiKey,
            admin: true,
          ),
          store: store,
          directory: directory,
          api: KomgaApi(
            Uri.parse('https://example.invalid'),
            authentication: Authentication.apiKey,
            credential: '',
            client: MockClient((request) async {
              dynamic data;
              switch (request.url.path) {
                case '/api/v1/komf/integration':
                  data = {'state': 'connected'};
                case '/api/v1/books/book':
                  data = {
                    'id': 'book',
                    'seriesId': 'series',
                    'libraryId': 'lib',
                    'metadata': {
                      'links': [
                        {'url': 'https://bgm.tv/subject/123'},
                        {'url': 'https://anilist.co/manga/34'},
                      ],
                    },
                  };
                case '/api/v1/series/series':
                  data = {
                    'id': 'series',
                    'libraryId': 'lib',
                    'oneshot': true,
                    'name': 'Original',
                    'metadata': {'title': 'Original'},
                  };
                case '/api/v1/komf/search':
                  final query = request.url.queryParameters['name'];
                  if (query == 'Older') return oldSearch.future;
                  data = [
                    {
                      'title': '$query provider result',
                      'provider': 'MANGADEX',
                      'resultId': 'chosen',
                    },
                  ];
                case '/api/v1/komf/identify':
                  submitted.add(object(jsonDecode(request.body)));
                  data = {'id': 'job'};
                case '/api/v1/komf/jobs/job':
                  data = {
                    'id': 'job',
                    'seriesId': 'series',
                    'status': 'COMPLETED',
                  };
                default:
                  data = {};
              }
              return http.Response(jsonEncode(data), 200);
            }),
          ),
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: KomfPage(
                repository: repository,
                item: CatalogItem('books', {'id': 'book', 'name': 'Oneshot'}),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Aggregate all providers'), findsOneWidget);
          expect(find.text('BANGUMI'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('Original provider result'),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('Original provider result'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byType(TextField));
          await tester.enterText(find.byType(TextField), 'Older');
          await tester.pump(const Duration(milliseconds: 350));
          await tester.enterText(find.byType(TextField), 'Newer');
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pump();
          oldSearch.complete(
            http.Response(
              '[{"title":"STALE result","provider":"MAL","resultId":"old"}]',
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('STALE result'), findsNothing);
          final chosen = find.text('Newer provider result');
          await tester.scrollUntilVisible(
            chosen,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(chosen);
          await tester.pump();
          await tester.pump();
          expect(submitted.single, {
            'libraryId': 'lib',
            'seriesId': 'series',
            'provider': 'MANGADEX',
            'providerSeriesId': 'chosen',
          });
          expect(repository.komf.jobs['job']!['status'], 'RUNNING');
          await tester.runAsync(repository.komf.pollJobs);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Komf job completed'),
            -150,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('Komf job completed'), findsOneWidget);
          expect(repository.contentRevision, 1);
          repository.setOffline(true);
          await tester.pump();
          expect(
            tester.widget<TextField>(find.byType(TextField)).enabled,
            false,
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (!oldSearch.isCompleted) {
            oldSearch.complete(http.Response('[]', 200));
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(repository.stopDownloadWork);
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
}
