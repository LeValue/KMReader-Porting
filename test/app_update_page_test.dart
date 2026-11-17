import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';

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

class PermissionUpdates extends FakeUpdates {
  @override
  Future<bool> install(AppUpdate update, File file) async => ++installs > 1;
}

class FailedUpdates extends FakeUpdates {
  FailedUpdates(this.failure, {this.duringInstall = false});
  final Object failure;
  final bool duringInstall;
  @override
  Future<File> download(
    AppUpdate update,
    Directory directory,
    void Function(int, int) progress,
  ) async {
    if (!duringInstall) throw failure;
    return super.download(update, directory, progress);
  }

  @override
  Future<bool> install(AppUpdate update, File file) async => throw failure;
}

class DeferredUpdates extends FakeUpdates {
  final pending = Completer<File>();
  @override
  Future<File> download(
    AppUpdate update,
    Directory directory,
    void Function(int, int) progress,
  ) {
    downloads++;
    return pending.future;
  }
}

void main() {
  testWidgets('two taps before rebuilding start only one update transfer', (
    tester,
  ) async {
    final updates = DeferredUpdates();
    await tester.pumpWidget(MaterialApp(home: AppUpdatePage(updates: updates)));
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    final button = find.text(
      Platform.isWindows ? 'Restart and update' : 'Install update',
    );
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(updates.downloads, 1);
    updates.pending.complete(File('synthetic-update.apk'));
    await tester.pumpAndSettle();
    expect(updates.installs, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'permission retry reuses the downloaded package without downloading again',
    (tester) async {
      final updates = PermissionUpdates();
      await tester.pumpWidget(
        MaterialApp(home: AppUpdatePage(updates: updates)),
      );
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      final label = Platform.isWindows
          ? 'Restart and update'
          : 'Install update';
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(updates.downloads, 1);
      expect(updates.installs, 1);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(updates.downloads, 1);
      expect(updates.installs, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final (failure, install) in <(Object, bool)>[
    (TimeoutException('synthetic-private-value'), false),
    (
      FileSystemException(
        'synthetic-private-value',
        'synthetic-private-value',
        const OSError('full', 28),
      ),
      false,
    ),
    (const FormatException('synthetic-private-value'), false),
    (
      PlatformException(
        code: 'update_signature',
        message: 'synthetic-private-value',
      ),
      true,
    ),
  ]) {
    testWidgets(
      'update page displays a safe ${failure.runtimeType} stage message',
      (tester) async {
        final updates = FailedUpdates(failure, duringInstall: install);
        await tester.pumpWidget(
          MaterialApp(home: AppUpdatePage(updates: updates)),
        );
        await tester.tap(find.text('Check for updates'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            Platform.isWindows ? 'Restart and update' : 'Install update',
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            updateFailureMessage(
              failure,
              stage: install ? 'install' : 'download',
            ),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('synthetic-private-value'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

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
