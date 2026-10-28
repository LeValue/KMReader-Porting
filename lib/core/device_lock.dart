import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import 'store.dart';

abstract interface class DeviceAuthenticator {
  Future<bool> supported();
  Future<bool> authenticate(String reason);
}

class SystemAuthenticator implements DeviceAuthenticator {
  final _auth = LocalAuthentication();
  @override
  Future<bool> supported() => _auth.isDeviceSupported();
  @override
  Future<bool> authenticate(String reason) => _auth.authenticate(
    localizedReason: reason,
    persistAcrossBackgrounding: true,
  );
}

/// Authentication failures leave the navigator covered. Changing the setting
/// in either direction requires successful OS authentication first.
class DeviceLock extends ChangeNotifier {
  DeviceLock(this.store, this.authenticator)
    : enabled = store.setting<bool>('deviceLock') ?? false,
      locked = store.setting<bool>('deviceLock') ?? false;
  final LocalStore store;
  final DeviceAuthenticator authenticator;
  bool enabled, locked;
  bool busy = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;

  void lock() {
    if (!enabled || busy || locked) return;
    _generation++;
    locked = true;
    notifyListeners();
  }

  Future<bool> _verify(String reason) async {
    if (busy) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (!await authenticator.supported()) {
        throw StateError(
          'Set up a screen lock or Windows Hello on this device.',
        );
      }
      return await authenticator.authenticate(reason);
    } catch (failure) {
      error = failure.toString();
      return false;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> unlock(String reason) async {
    if (!locked || busy) return;
    final generation = _generation;
    if (await _verify(reason) && !_disposed && generation == _generation) {
      locked = false;
      notifyListeners();
    }
  }

  Future<void> configure(bool value, String reason) async {
    if (value == enabled || busy) return;
    if (!await _verify(reason) || _disposed) return;
    enabled = value;
    locked = false;
    store.setSetting('deviceLock', value);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
