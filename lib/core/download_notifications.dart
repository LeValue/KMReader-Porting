import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models.dart';
import 'store.dart';

class DownloadNotifications {
  static const setting = 'systemDownloadNotifications';
  static final _plugin = FlutterLocalNotificationsPlugin();
  static final _events = StreamController<void>.broadcast();
  static Future<bool>? _initialized;
  static String? _pending;
  static Stream<void> get events => _events.stream;
  static String? get pending => _pending;
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  static Future<bool> initialize() => _initialized ??= _initialize();

  static Future<bool> _initialize() async {
    if (!supported) return false;
    try {
      final ready = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('shortcut_downloads'),
          windows: WindowsInitializationSettings(
            appName: 'KMReader',
            appUserModelId: 'dev.levalue.kmreader',
            guid: 'f42c739f-96d1-4a9c-a1ba-c89ec82e4aed',
          ),
        ),
        onDidReceiveNotificationResponse: (response) =>
            _activate(response.payload),
      );
      if (ready != true) return false;
      final startup = await _plugin.getNotificationAppLaunchDetails();
      if (startup?.didNotificationLaunchApp == true) {
        _activate(startup?.notificationResponse?.payload);
      }
      return true;
    } on Exception {
      return false;
    }
  }

  static void _activate(String? payload) {
    if (payload == null || payload.isEmpty) return;
    _pending = payload;
    _events.add(null);
  }

  static void discard(String profile) {
    if (_pending == profile) _pending = null;
  }

  static Future<bool> enable() async {
    if (!await initialize()) return false;
    if (!Platform.isAndroid) return true;
    return await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission() ??
        false;
  }

  static Future<void> show(
    LocalStore store,
    ServerProfile profile,
    String book, {
    required bool completed,
  }) async {
    if (!supported ||
        store.setting<bool>(setting) != true ||
        store.setting<bool>('privacyProtection') == true ||
        store.servers
                .where((saved) => saved.id == profile.id)
                .firstOrNull
                ?.isProtected !=
            false) {
      return;
    }
    final italian = (store.setting<String>('language') ?? Platform.localeName)
        .toLowerCase()
        .startsWith('it');
    final digest = sha256.convert(utf8.encode('${profile.id}:$book')).bytes;
    final id =
        (digest[0] & 0x7f) << 24 | digest[1] << 16 | digest[2] << 8 | digest[3];
    if (!await initialize()) return;
    try {
      await _plugin.show(
        id: id,
        title: 'KMReader',
        body: completed
            ? (italian ? 'Download completato' : 'Download complete')
            : (italian ? 'Download da riprendere' : 'Download needs attention'),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'kmreader_downloads',
            italian ? 'Download' : 'Downloads',
            visibility: NotificationVisibility.private,
          ),
        ),
        payload: profile.id,
      );
    } on Exception {
      // A notification failure must never change the transfer result.
    }
  }
}
