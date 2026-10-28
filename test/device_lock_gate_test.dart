import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/device_lock.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/ui/device_lock_gate.dart';
import 'package:sqlite3/sqlite3.dart';

import 'device_lock_test.dart' show Auth;

void main() {
  testWidgets(
    'locked navigator is hidden and OS screenshot protection follows verified settings',
    (tester) async {
      final store = LocalStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final auth = Auth(), lock = DeviceLock(store, auth);
      addTearDown(lock.dispose);
      const channel = MethodChannel('dev.levalue.kmreader/privacy');
      final protection = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        protection.add(call.arguments as bool);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              DeviceLockGate(lock: lock, child: child!),
          home: const Scaffold(body: Text('Private reading position')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private reading position'), findsOneWidget);
      await lock.configure(true, 'Enable');
      lock.lock();
      await tester.pumpAndSettle();
      expect(find.text('Private reading position'), findsNothing);
      expect(find.text('KMReader is locked'), findsOneWidget);
      expect(protection.last, true);
      auth.answer = false;
      await lock.configure(false, 'Disable');
      await tester.pumpAndSettle();
      expect(lock.locked, true);
      expect(protection.last, true);
      auth.answer = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Private reading position'), findsOneWidget);
      await lock.configure(false, 'Disable');
      await tester.pumpAndSettle();
      expect(protection.last, false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'cancelled authentication is not repeated by the same foreground transition',
    (tester) async {
      final store = LocalStore(sqlite3.openInMemory());
      addTearDown(store.close);
      store.setSetting('deviceLock', true);
      final auth = Auth()..answer = false;
      final lock = DeviceLock(store, auth);
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              DeviceLockGate(lock: lock, child: child!),
          home: const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.calls, 1);
      expect(lock.locked, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
