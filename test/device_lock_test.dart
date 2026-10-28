import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/device_lock.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

class Auth implements DeviceAuthenticator {
  bool available = true;
  bool answer = true;
  Completer<bool>? pending;
  int calls = 0;
  @override
  Future<bool> supported() async => available;
  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    return pending?.future ?? Future.value(answer);
  }
}

void main() {
  test('enabling, disabling and unlocking require successful device authentication', () async {
    final store = LocalStore(sqlite3.openInMemory());
    addTearDown(store.close);
    final auth = Auth();
    final lock = DeviceLock(store, auth);
    addTearDown(lock.dispose);
    auth.available = false;
    await lock.configure(true, 'enable');
    expect(lock.enabled, false);
    expect(auth.calls, 0);
    auth.available = true;
    auth.answer = false;
    await lock.configure(true, 'enable');
    expect(lock.enabled, false);
    auth.answer = true;
    await lock.configure(true, 'enable');
    expect(lock.enabled, true);
    expect(store.setting<bool>('deviceLock'), true);
    lock.lock();
    auth.answer = false;
    await lock.unlock('unlock');
    expect(lock.locked, true);
    await lock.configure(false, 'disable');
    expect(lock.enabled, true);
    auth.answer = true;
    await lock.unlock('unlock');
    expect(lock.locked, false);
    lock.lock();
    await lock.configure(false, 'disable');
    expect(lock.enabled, false);
    expect(lock.locked, false);
  });
  test('cold launch stays locked, overlapping requests coalesce and disposal cannot unlock', () async {
    final store = LocalStore(sqlite3.openInMemory());
    addTearDown(store.close);
    store.setSetting('deviceLock', true);
    final auth = Auth()..pending = Completer<bool>();
    final lock = DeviceLock(store, auth);
    expect(lock.locked, true);
    final result = lock.unlock('unlock');
    await Future<void>.delayed(Duration.zero);
    await lock.unlock('duplicate');
    expect(auth.calls, 1);
    expect(lock.locked, true);
    lock.dispose();
    auth.pending!.complete(true);
    await result;
    expect(lock.locked, true);
  });
}
