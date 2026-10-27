import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'api.dart';
import 'models.dart';
import 'repository.dart';
import 'store.dart';

abstract class CredentialVault {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

class SecureVault implements CredentialVault {
  const SecureVault();
  static const storage = FlutterSecureStorage();
  @override
  Future<String?> read(String id) => storage.read(key: 'server:$id');
  @override
  Future<void> write(String id, String value) =>
      storage.write(key: 'server:$id', value: value);
  @override
  Future<void> delete(String id) => storage.delete(key: 'server:$id');
}

class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.directory,
    required this.vault,
  });
  final LocalStore store;
  final Directory directory;
  final CredentialVault vault;
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
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final controller = AppController(
      store: LocalStore(sqlite3.open(p.join(dir.path, 'kmreader.sqlite'))),
      directory: dir,
      vault: const SecureVault(),
    );
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
  }) async {
    final base = normalizeServerUrl(address);
    final credential = authentication == Authentication.apiKey
        ? password.trim()
        : base64Encode(utf8.encode('$username:$password'));
    final api = KomgaApi(
      base,
      authentication: authentication,
      credential: credential,
    );
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
      final profile = ServerProfile(
        id: ServerProfile.identity(base, text(user['id'])),
        name: name.trim().isEmpty ? base.host : name.trim(),
        url: base.toString(),
        email: text(user['email']),
        authentication: authentication,
        admin: (user['roles'] as List? ?? []).contains('ADMIN'),
      );
      await vault.write(profile.id, credential);
      store.saveServer(profile);
      await activate(profile);
      return profile;
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
    repository?.dispose();
    repository = Repository(
      profile: profile,
      api: KomgaApi(
        Uri.parse(profile.url),
        authentication: profile.authentication,
        credential: credential,
      ),
      store: store,
      directory: directory,
    );
    store.setSetting('activeServer', profile.id);
    startupError = null;
    repository!.listen();
    unawaited(repository!.sync());
    notifyListeners();
  }

  Future<void> remove(ServerProfile profile) async {
    if (repository?.profile.id == profile.id) {
      _selection++;
      repository?.dispose();
      repository = null;
    }
    await vault.delete(profile.id);
    store.removeServer(profile.id);
    final dir = Directory(p.join(directory.path, profile.id));
    if (await dir.exists()) await dir.delete(recursive: true);
    notifyListeners();
  }

  void disconnect() {
    _selection++;
    repository?.dispose();
    repository = null;
    store.setSetting('activeServer', null);
    notifyListeners();
  }
}
