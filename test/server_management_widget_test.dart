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
import 'package:kmreader/features/settings/server_management_page.dart';
import 'package:kmreader/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(Strings.initialize);
  for (final width in [320.0, 1280.0]) {
    testWidgets('server management tabs fit $width pixels with enlarged text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('admin-layout-');
      final store = LocalStore(sqlite3.openInMemory());
      final repository = Repository(
        profile: const ServerProfile(
          id: 's',
          name: 'Fixture',
          url: 'https://example.invalid',
          email: 'fixture@example.invalid',
          authentication: Authentication.apiKey,
          admin: true,
        ),
        directory: directory,
        store: store,
        api: KomgaApi(
          Uri.parse('https://example.invalid'),
          authentication: Authentication.apiKey,
          credential: '',
          client: MockClient((request) async {
            if (request.url.path == '/api/v1/stats/server') {
              return http.Response('', 404);
            }
            if (request.url.path.contains('/metrics/')) {
              return http.Response(
                jsonEncode({
                  'availableTags': [
                    {
                      'tag': 'type',
                      'values': ['Analyze'],
                    },
                  ],
                  'measurements': [
                    {'statistic': 'COUNT', 'value': 12},
                    {'statistic': 'TOTAL_TIME', 'value': 4.5},
                    {'statistic': 'MAX', 'value': 1},
                  ],
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/scheduledtasks')) {
              return http.Response(
                jsonEncode({
                  'fixedRate': [
                    {
                      'runnable': {'target': 'com.example.ScheduledTask'},
                      'interval': 5000,
                    },
                  ],
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/sessions')) {
              return http.Response(
                jsonEncode({
                  'sessions': [
                    {
                      'id': 'session',
                      'creationTime': '2026-01-01T00:00:00Z',
                      'lastAccessedTime': '2026-01-02T00:00:00Z',
                      'expired': false,
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response('Synthetic log', 206);
          }),
        ),
      );
      repository.taskQueueStatus.value = {
        'count': 2,
        'countByType': {'Analyze': 2},
      };
      try {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: ServerManagementPage(repository: repository),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Task Queue'), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final tab in ['Scheduled Tasks', 'Sessions', 'Logs']) {
          final target = find.widgetWithText(Tab, tab);
          await tester.ensureVisible(target);
          await tester.tap(target);
          // The lazy page is created after the tab animation. Let its streamed
          // HTTP response complete before waiting for loading animations to stop.
          for (var frame = 0; frame < 10; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          await tester.pumpAndSettle();
          expect(
            find.text(switch (tab) {
              'Scheduled Tasks' => 'com.example.ScheduledTask',
              'Sessions' => 'session',
              _ => 'Synthetic log',
            }),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: tab);
        }
        expect(find.text('Synthetic log'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(repository.stopDownloadWork);
        store.close();
        directory.deleteSync(recursive: true);
      }
    });
  }
}
