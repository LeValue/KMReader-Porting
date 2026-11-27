import 'dart:async';

import 'package:flutter/services.dart';

enum SystemAction { search, downloads, reading }

class AndroidSystemActions {
  static const _channel = MethodChannel('dev.levalue.kmreader/shortcuts');
  static final _events = StreamController<void>.broadcast();
  static bool _listening = false;

  static Stream<void> get events {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'actionAvailable') _events.add(null);
      });
    }
    return _events.stream;
  }

  static Future<SystemAction?> take() async {
    try {
      final name = await _channel.invokeMethod<String>('takeAction');
      return SystemAction.values
          .where((action) => action.name == name)
          .firstOrNull;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
