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
import 'package:kmreader/features/catalog/history_page.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(Strings.initialize);
  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'own authentication activity paginates, retries refresh and opens offline at $width px',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync('auth-activity-');
        final store = LocalStore(sqlite3.openInMemory());
        var generation = 'Old', deny = false;
        final pages = <int>[];
        final repository = Repository(
          profile: const ServerProfile(
            id: 'reader',
            name: 'Fixture',
            url: 'https://example.invalid/base',
            email: 'reader@example.invalid',
            authentication: Authentication.apiKey,
          ),
          store: store,
          directory: directory,
          api: KomgaApi(
            Uri.parse('https://example.invalid/base'),
            authentication: Authentication.apiKey,
            credential: 'synthetic-key',
            client: MockClient((request) async {
              expectSync(
                request.url.path,
                '/base/api/v2/users/me/authentication-activity',
              );
              expectSync(request.url.queryParameters['size'], '20');
              expectSync(
                request.url.queryParameters.containsKey('sort'),
                false,
              );
              final page = int.parse(request.url.queryParameters['page']!);
              pages.add(page);
              if (deny) return http.Response('', 403);
              return http.Response(
                jsonEncode({
                  'content': [
                    for (var i = page * 20; i < (page == 0 ? 20 : 30); i++)
                      {
                        'source': '$generation $i',
                        'success': i.isEven,
                        'dateTime': DateTime.utc(
                          2026,
                          1,
                          1,
                          0,
                          i,
                        ).toIso8601String(),
                        'apiKeyComment': 'Fixture key',
                        'ip': '127.0.0.1',
                        'userAgent': 'Synthetic test agent',
                        if (i.isOdd) 'error': 'Synthetic rejection',
                      },
                  ],
                  'last': page >= 1,
                }),
                200,
              );
            }),
          ),
        );
        Widget page() => MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: AuthenticationActivityPage(repository: repository),
        );
        try {
          await tester.pumpWidget(page());
          await tester.pumpAndSettle();
          expect(find.text('Old 0'), findsOneWidget);
          await tester.tap(find.text('Old 0'));
          await tester.pumpAndSettle();
          expect(find.text('Fixture key'), findsOneWidget);
          expect(find.text('127.0.0.1'), findsOneWidget);
          expect(find.text('Synthetic test agent'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('Old 29'),
            500,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(pages, [0, 1]);
          expect(tester.takeException(), isNull);
          deny = true;
          final refreshed = tester
              .widget<RefreshIndicator>(find.byType(RefreshIndicator))
              .onRefresh();
          await tester.pumpAndSettle();
          await refreshed;
          expect(pages, [0, 1, 0]);
          deny = false;
          generation = 'Fresh';
          await tester.scrollUntilVisible(
            find.text('Retry'),
            500,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Fresh 0'),
            -500,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(find.text('Old 0'), findsNothing);
          expect(pages[2], 0);
          expect(pages[3], 0);
          repository.setOffline(true);
          final count = pages.length;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(page());
          await tester.pumpAndSettle();
          expect(find.text('Fresh 0'), findsOneWidget);
          expect(pages, hasLength(count));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(repository.stopDownloadWork);
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
}
