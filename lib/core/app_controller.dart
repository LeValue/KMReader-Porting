import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

export 'credentials.dart';

import 'api.dart';
import 'credentials.dart';
import 'background_downloads.dart';
import 'device_lock.dart';
import 'models.dart';
import 'repository.dart';
import 'store.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.directory,
    required this.vault,
    this.apiFactory,
  });
  late final BackgroundDownloads backgroundDownloads = BackgroundDownloads(
    store,
    directory,
  );
  late final DeviceLock deviceLock = DeviceLock(store, SystemAuthenticator());
  final LocalStore store;
  final Directory directory;
  final CredentialVault vault;
  final KomgaApi Function(Uri, Authentication, String)? apiFactory;
  KomgaApi _api(Uri base, Authentication authentication, String credential) =>
      apiFactory?.call(base, authentication, credential) ??
      KomgaApi(base, authentication: authentication, credential: credential);
  Repository? repository;
  String? startupError;
  int _selection = 0;
  List<ServerProfile> get servers => store.servers;
  ThemeMode get theme => ThemeMode.values.firstWhere(
    (v) => v.name == store.setting<String>('theme'),
    orElse: () => ThemeMode.system,
  );
  String? get language => store.setting<String>('language');
  void setTheme(ThemeMode value) {
    store.setSetting('theme', value.name);
    notifyListeners();
  }

  void setLanguage(String? value) {
    store.setSetting('language', value);
    notifyListeners();
  }

  static Future<AppController> open() async {
    final override = Platform.environment['KMREADER_DATA_DIR'];
    final dir = override != null && override.isNotEmpty
        ? Directory(override)
        : await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final controller = AppController(
      store: LocalStore(sqlite3.open(p.join(dir.path, 'kmreader.sqlite'))),
      directory: dir,
      vault: const SecureVault(),
    );
    try {
      await controller.backgroundDownloads.initialize();
    } catch (error) {
      controller.backgroundDownloads.failure = error.toString();
    }
    final last = controller.store.setting<String>('activeServer');
    final profile = controller.servers.where((s) => s.id == last).firstOrNull;
    if (profile != null) {
      try {
        await controller.activate(profile);
      } catch (e) {
        controller.startupError = e.toString();
      }
    }
    return controller;
  }

  Future<ServerProfile> login({
    required String address,
    required String name,
    required Authentication authentication,
    required String username,
    required String password,
    bool claim = false,
    bool autoCreateApiKey = true,
  }) async {
    final base = normalizeServerUrl(address);
    var credential = authentication == Authentication.apiKey
        ? password.trim()
        : base64Encode(utf8.encode('$username:$password'));
    final api = _api(base, authentication, credential);
    String? createdKeyId;
    try {
      await api.request('/api/v1/client-settings/global/list');
      if (claim) {
        await api.request(
          '/api/v1/claim',
          method: 'POST',
          extra: {'X-Komga-Email': username, 'X-Komga-Password': password},
        );
      }
      final user = await api.user();
      var method = authentication;
      if (authentication == Authentication.password && autoCreateApiKey) {
        try {
          final key = object(
            await api.request(
              '/api/v2/users/me/api-keys',
              method: 'POST',
              body: {'comment': 'KMReader ${Platform.operatingSystem}'},
            ),
          );
          createdKeyId = text(key['id']);
          final secret = text(key['key']);
          if (createdKeyId.isEmpty || secret.isEmpty) {
            throw const ApiFailure('The server did not return an API key.');
          }
          final verification = _api(base, Authentication.apiKey, secret);
          try {
            final verified = await verification.user();
            if (verified['id'] != user['id']) {
              throw const ApiFailure(
                'The API key belongs to a different account.',
              );
            }
          } finally {
            verification.close();
          }
          credential = secret;
          method = Authentication.apiKey;
        } catch (_) {
          if (createdKeyId != null && createdKeyId.isNotEmpty) {
            try {
              await api.request(
                '/api/v2/users/me/api-keys/${Uri.encodeComponent(createdKeyId)}',
                method: 'DELETE',
              );
            } catch (_) {
              /* Failed verification must preserve password login. */
            }
          }
          createdKeyId = null;
        }
      }
      final profile = ServerProfile(
        id: ServerProfile.identity(base, text(user['id'])),
        name: name.trim().isEmpty ? base.host : name.trim(),
        url: base.toString(),
        email: text(user['email']),
        authentication: method,
        apiKeyId: createdKeyId,
        managedKey: createdKeyId != null,
        userId: text(user['id']),
        admin: (user['roles'] as List? ?? []).contains('ADMIN'),
      );
      final previous = servers.where((s) => s.id == profile.id).firstOrNull;
      await vault.write(profile.id, credential);
      store.saveServer(profile);
      await activate(profile);
      if (createdKeyId != null &&
          previous?.managedKey == true &&
          previous?.apiKeyId != null &&
          previous!.apiKeyId != createdKeyId) {
        try {
          await api.request(
            '/api/v2/users/me/api-keys/${Uri.encodeComponent(previous.apiKeyId!)}',
            method: 'DELETE',
          );
        } catch (_) {
          /* A key cleanup failure must not undo a verified login. */
        }
      }
      return profile;
    } catch (_) {
      if (createdKeyId != null && createdKeyId.isNotEmpty) {
        try {
          await api.request(
            '/api/v2/users/me/api-keys/${Uri.encodeComponent(createdKeyId)}',
            method: 'DELETE',
          );
        } catch (_) {
          /* The caller still receives the original login/storage failure. */
        }
      }
      rethrow;
    } finally {
      api.close();
    }
  }

  Future<void> activate(ServerProfile profile) async {
    final generation = ++_selection;
    final credential = await vault.read(profile.id);
    if (generation != _selection) return;
    if (credential == null) {
      throw const ApiFailure(
        'Saved credentials are unavailable. Sign in to this server again.',
      );
    }
    backgroundDownloads.attach(null);
    await repository?.stopDownloadWork();
    if (generation != _selection) return;
    repository = Repository(
      profile: profile,
      api: _api(Uri.parse(profile.url), profile.authentication, credential),
      store: store,
      directory: directory,
    );
    store.setSetting('activeServer', profile.id);
    startupError = null;
    repository!.offline = store.setting<bool>('offline:${profile.id}') == true;
    backgroundDownloads.attach(repository);
    if (!repository!.offline) {
      repository!.listen();
      unawaited(repository!.sync());
    }
    notifyListeners();
  }

  Future<void> remove(ServerProfile profile) async {
    if (repository?.profile.id == profile.id) {
      _selection++;
      backgroundDownloads.attach(null);
      await repository?.stopDownloadWork();
      repository = null;
    }
    // Tombstone first: a worker already running cannot recreate this account.
    store.removeServer(profile.id);
    await backgroundDownloads.removeProfile(profile.id);
    await vault.delete(profile.id);
    // Running engines observe the tombstone, abort their streams, and release.
    // A crashed process loses its bounded lease after at most 30 seconds.
    while (store.accountTransferring(profile.id)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final dir = Directory(p.join(directory.path, profile.id));
    if (await dir.exists()) await dir.delete(recursive: true);
    notifyListeners();
  }

  void disconnect() {
    _selection++;
    backgroundDownloads.attach(null);
    repository?.dispose();
    repository = null;
    store.setSetting('activeServer', null);
    notifyListeners();
  }
}
