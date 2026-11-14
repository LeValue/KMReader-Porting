import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:kmreader/core/updates/app_updates.dart';
import 'package:kmreader/features/settings/app_update_page.dart';

class FakeUpdates extends AppUpdates {
  FakeUpdates()
    : super(client: MockClient((_) async => http.Response('', 500)));
  int downloads = 0, installs = 0, restarts = 0;
  @override
  Future<void> requestRestart() async {
    restarts++;
  }

  @override
  Future<bool> previousInstallFailed() async => false;
  @override
  Future<AppUpdate?> check(String platform) async => AppUpdate(
    '1.0.0',
    999,
    'a' * 40,
    Uri.parse('${updateOrigin}tag/app.apk'),
    'b' * 64,
    100,
  );
  @override
  Future<Directory> storageDirectory() async => Directory.systemTemp;
  @override
  Future<File> download(
    AppUpdate update,
    Directory directory,
    void Function(int, int) progress,
  ) async {
    downloads++;
    progress(100, 100);
    return File('${directory.path}/synthetic-update.apk');
  }

  @override
  Future<bool> install(AppUpdate update, File file) async {
    installs++;
    return true;
  }
}

void main() {
  testWidgets(
    'checking never installs; download and installer require an explicit action',
    (tester) async {
      final updates = FakeUpdates();
      await tester.pumpWidget(
        MaterialApp(home: AppUpdatePage(updates: updates)),
      );
      expect(updates.installs, 0);
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.textContaining('999'), findsOneWidget);
      expect(updates.downloads, 0);
      expect(updates.installs, 0);
      await tester.tap(
        find.text(Platform.isWindows ? 'Restart and update' : 'Install update'),
      );
      await tester.pumpAndSettle();
      expect(updates.downloads, 1);
      expect(updates.installs, 1);
      if (Platform.isWindows) {
        expect(updates.restarts, 1);
      } else {
        expect(
          find.text('Confirm the update in the system installer.'),
          findsOneWidget,
        );
        expect(updates.restarts, 0);
      }
    },
  );
}
