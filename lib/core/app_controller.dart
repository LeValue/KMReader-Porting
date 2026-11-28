import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

export 'credentials.dart';

import 'api.dart';
import 'local_library.dart';
import 'local_folders.dart';
import 'kindle/client.dart';
import 'kindle/repository.dart';
import 'network_preferences.dart';
import 'reader_defaults.dart';
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
    this.kindleClientFactory,
    this.deviceAuthenticator,
    this.standaloneReader = false,
  });
  late final BackgroundDownloads backgroundDownloads = BackgroundDownloads(
    store,
    directory,
  );
  late final DeviceLock deviceLock = DeviceLock(
    store,
    deviceAuthenticator ?? SystemAuthenticator(),
  );
  late final LocalLibrary localLibrary = LocalLibrary(
    store: store,
    directory: directory,
  );
  late final LocalFolders localFolders = LocalFolders(localLibrary);
  final LocalStore store;
  final Directory directory;
  final CredentialVault vault;
  final DeviceAuthenticator? deviceAuthenticator;
  final bool standaloneReader;
  final KomgaApi Function(Uri, Authentication, String)? apiFactory;
  final KindleClient Function(
    KindleSession,
    Future<void> Function(KindleSession),
  )?
  kindleClientFactory;
  KomgaApi _api(Uri base, Authentication authentication, String credential) {
    final api =
        apiFactory?.call(base, authentication, credential) ??
        KomgaApi(base, authentication: authentication, credential: credential);
    api.readNetworkPreferences = () => NetworkPreferences.fromStore(store);
    return api;
  }

  void settingsChanged() {
    if (!standaloneReader) backgroundDownloads.refresh();
    notifyListeners();
  }

  Future<void> setAppIcon(String name) async {
    if (!const ['default', 'classic', 'legacy'].contains(name)) {
      throw ArgumentError.value(name);
    }
    await const MethodChannel('dev.levalue.kmreader/privacy')
        .invokeMethod<void>('setAppIcon', name);
    store.setSetting('appIcon', name);
    notifyListeners();
  }

  Repository? repository;
  String? startupError;
  int _selection = 0;
  bool _choosingProtectedServer = false;
  bool get protectedServerVisible =>
      _choosingProtectedServer || repository?.profile.isProtected == true;
  List<ServerProfile> get servers => store.servers;
  List<ServerProfile> get visibleServers => servers
      .where(
        (profile) =>
            !profile.isProtected || profile.id == repository?.profile.id,
      )
      .toList();
  bool get hasProtectedServers => servers.any((profile) => profile.isProtected);
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

  static Future<AppController> open({bool standaloneReader = false}) async {
    final override = Platform.environment['KMREADER_DATA_DIR'];
    final dir = override != null && override.isNotEmpty
        ? Directory(override)
        : await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final controller = AppController(
      store: LocalStore(sqlite3.open(p.join(dir.path, 'kmreader.sqlite'))),
      directory: dir,
      vault: const SecureVault(),
      standaloneReader: standaloneReader,
    );
    initializeReaderDefaults(controller.store);
    if (standaloneReader) return controller;
    final last = controller.store.setting<String>('activeServer');
    final profile = controller.servers.where((s) => s.id == last).firstOrNull;
    if (profile != null && !profile.isProtected) {
      try {
        await controller.activate(profile);
      } catch (e) {
        controller.startupError = e.toString();
      }
    }
    return controller;
  }

  Future<void> startBackgroundServices() async {
    if (standaloneReader) return;
    if (store.setting<List<dynamic>>('localImportFolders')?.isNotEmpty ==
        true) {
      localFolders.start();
    }
    final savedIcon = store.setting<dynamic>('appIcon');
    if (Platform.isWindows &&
        const ['default', 'classic', 'legacy'].contains(savedIcon)) {
      try {
        await setAppIcon(savedIcon as String);
      } on PlatformException {
        /* Keep the system icon if unavailable. */
      } on MissingPluginException {
        /* Older native hosts use the default icon. */
      }
    }
    try {
      await backgroundDownloads.initialize();
    } catch (error) {
      backgroundDownloads.failure = error.toString();
    }
  }

  Future<ServerProfile> login({
    required String address,
    required String name,
    required Authentication authentication,
    required String username,
    required String password,
    bool claim = false,
    bool autoCreateApiKey = true,
    String? authenticationReason,
  }) async {
    final base = normalizeServerUrl(address);
    var credential = authentication == Authentication.apiKey
        ? password.trim()
        : base64Encode(utf8.encode('$username:$password'));
    final api = _api(base, authentication, credential)..authenticating = true;
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
      final userId = text(user['id']);
      if (userId.isEmpty) {
        throw const ApiFailure('Could not verify the account.');
      }
      final identity = ServerProfile.identity(base, userId);
      final previous = servers
          .where(
            (profile) =>
                !profile.isKindle &&
                profile.url == base.toString() &&
                (profile.userId == userId ||
                    profile.userId == null && profile.id == identity),
          )
          .firstOrNull;
      if (previous == null &&
          servers.any((profile) => profile.id == identity)) {
        throw const ApiFailure(
          'This server address has moved. Open the saved profile to edit its address.',
        );
      }
      final id = previous?.id ?? identity;
      if (previous?.isProtected == true) {
        await _requireDeviceAccess(
          authenticationReason ?? 'Authenticate to open this server.',
        );
      }
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
      final knownKey =
          method == Authentication.apiKey &&
          createdKeyId == null &&
          previous?.authentication == Authentication.apiKey &&
          await vault.read(previous!.credentialKey) == credential;
      final profile = ServerProfile(
        id: id,
        name: name.trim().isEmpty ? base.host : name.trim(),
        url: base.toString(),
        email: text(user['email']),
        authentication: method,
        apiKeyId: createdKeyId ?? (knownKey ? previous.apiKeyId : null),
        managedKey: createdKeyId != null || knownKey && previous.managedKey,
        userId: userId,
        admin: (user['roles'] as List? ?? []).contains('ADMIN'),
        isProtected: previous?.isProtected ?? false,
        credentialSlot: previous?.credentialSlot,
      );
      await vault.write(profile.credentialKey, credential);
      store.saveServer(profile);
      store.setSetting('offline:${profile.id}', false);
      await _activate(profile);
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

  Future<void> changePassword(Repository target, String password) async {
    if (!identical(repository, target) || target.closed) {
      throw const ApiFailure('The server connection was closed.');
    }
    if (target.offline) {
      throw const ApiFailure('Reconnect to manage the server.', offline: true);
    }
    if (password.isEmpty) throw const ApiFailure('Enter a new password.');
    final selection = _selection;
    final profile = target.profile;
    final userId = profile.userId ?? text((await target.api.user())['id']);
    if (userId.isEmpty) {
      throw const ApiFailure('The server returned an unexpected response.');
    }
    final credential = base64Encode(utf8.encode('${profile.email}:$password'));
    try {
      await target.api.request(
        '/api/v2/users/${Uri.encodeComponent(userId)}/password',
        method: 'PATCH',
        body: {'password': password},
      );
    } on ApiFailure catch (error) {
      if (!error.offline || profile.authentication != Authentication.password) {
        rethrow;
      }
      // A lost response can follow an applied password change. Verify the new
      // credential instead of replaying the mutation with the obsolete one.
      final probe = _api(
        Uri.parse(profile.url),
        Authentication.password,
        credential,
      );
      var applied = false;
      try {
        applied = (await probe.user())['id'] == userId;
      } catch (_) {
        /* Keep the original transport failure if verification fails. */
      } finally {
        probe.close();
      }
      if (!applied) rethrow;
    }
    if (profile.authentication != Authentication.password) return;
    final saved = servers.where((s) => s.id == profile.id).firstOrNull;
    if (saved == null ||
        saved.authentication != Authentication.password ||
        saved.credentialKey != profile.credentialKey ||
        saved.url != profile.url) {
      return;
    }
    try {
      await vault.write(profile.credentialKey, credential);
    } catch (_) {
      if (selection == _selection && identical(repository, target)) {
        disconnect();
      }
      throw const ApiFailure(
        'Password changed. Sign in again to save the new credentials on this device.',
      );
    }
    if (!servers.any((s) => s.credentialKey == profile.credentialKey)) {
      await vault.delete(profile.credentialKey);
      return;
    }
    if (selection == _selection && identical(repository, target)) {
      await _activate(saved);
    }
  }

  Future<void> _requireDeviceAccess(String reason) async {
    if (!await deviceLock.verifyAccess(reason)) {
      throw const ApiFailure('Device authentication is required.');
    }
  }

  ServerProfile _savedServer(String id) =>
      servers.where((profile) => profile.id == id).firstOrNull ??
      (throw const ApiFailure('This server is no longer saved.'));

  Future<void> chooseProtectedServer(
    String reason,
    Future<ServerProfile?> Function(List<ServerProfile>) choose,
  ) async {
    await _requireDeviceAccess(reason);
    final profiles = servers.where((profile) => profile.isProtected).toList();
    if (_choosingProtectedServer) return;
    final selection = _selection;
    _choosingProtectedServer = true;
    notifyListeners();
    try {
      final selected = await choose(profiles);
      if (selected != null &&
          selection == _selection &&
          profiles.any((profile) => profile.id == selected.id)) {
        await _activate(_savedServer(selected.id));
      }
    } finally {
      _choosingProtectedServer = false;
      notifyListeners();
    }
  }

  Future<void> updateServer(
    ServerProfile existing, {
    required String name,
    required bool isProtected,
    required String authenticationReason,
    String? address,
    Authentication? authentication,
    String? secret,
  }) async {
    final profile = _savedServer(existing.id);
    if (profile.isKindle) {
      throw const ApiFailure('This account cannot be edited here.');
    }
    if (jsonEncode(existing.toJson()) != jsonEncode(profile.toJson())) {
      throw const ApiFailure(
        'This server changed. Reopen the editor and try again.',
      );
    }
    final method = authentication ?? profile.authentication;
    final originalBase = Uri.parse(profile.url);
    final base = address == null ? originalBase : normalizeServerUrl(address);
    final moved = base != originalBase;
    final replace = secret != null && secret.isNotEmpty;
    if (moved && !replace) {
      throw const ApiFailure('Enter credentials for the new server address.');
    }
    if (method != profile.authentication && !replace) {
      throw const ApiFailure(
        'Enter credentials for the selected sign-in method.',
      );
    }
    if (profile.isProtected || isProtected) {
      await _requireDeviceAccess(authenticationReason);
    }
    final oldCredential = replace
        ? await vault.read(profile.credentialKey)
        : null;
    String? credential;
    var admin = profile.admin;
    var email = profile.email;
    var userId = profile.userId;
    if (replace) {
      final proposed = method == Authentication.apiKey
          ? secret.trim()
          : base64Encode(utf8.encode('${profile.email}:$secret'));
      if (proposed.isEmpty) throw const ApiFailure('Enter valid credentials.');
      final api = _api(base, method, proposed)..authenticating = true;
      try {
        final user = await api.user();
        final id = text(user['id']);
        if (id.isEmpty ||
            (userId != null
                ? id != userId
                : ServerProfile.identity(originalBase, id) != profile.id)) {
          throw const ApiFailure(
            'The credentials belong to a different account.',
          );
        }
        userId = id;
        email = text(user['email'], profile.email);
        admin = (user['roles'] as List? ?? []).contains('ADMIN');
        if (moved ||
            method != profile.authentication ||
            proposed != oldCredential) {
          credential = proposed;
        }
      } finally {
        api.close();
      }
    }
    final random = moved ? Random.secure() : null;
    final newSlot = random == null
        ? profile.credentialSlot
        : '${profile.id}:${base64Url.encode(List<int>.generate(18, (_) => random.nextInt(256)))}';
    final updated = ServerProfile(
      id: profile.id,
      name: name.trim().isEmpty ? base.host : name.trim(),
      url: base.toString(),
      email: email,
      authentication: method,
      admin: admin,
      apiKeyId: credential == null ? profile.apiKeyId : null,
      managedKey: credential == null && profile.managedKey,
      userId: userId,
      isProtected: isProtected,
      credentialSlot: newSlot,
    );
    if (jsonEncode(_savedServer(profile.id).toJson()) !=
        jsonEncode(profile.toJson())) {
      throw const ApiFailure(
        'This server changed. Reopen the editor and try again.',
      );
    }
    if (credential != null) {
      await vault.write(updated.credentialKey, credential);
    }
    try {
      if (jsonEncode(_savedServer(profile.id).toJson()) !=
          jsonEncode(profile.toJson())) {
        throw const ApiFailure(
          'This server changed. Reopen the editor and try again.',
        );
      }
      if (moved &&
          servers.any(
            (saved) =>
                saved.id != profile.id &&
                !saved.isKindle &&
                saved.url == updated.url &&
                (saved.userId == updated.userId ||
                    saved.userId == null &&
                        saved.id ==
                            ServerProfile.identity(base, updated.userId!)),
          )) {
        throw const ApiFailure(
          'This account is already saved at the new address.',
        );
      }
      store.saveServer(updated);
    } catch (_) {
      if (credential != null &&
          await vault.read(updated.credentialKey) == credential) {
        if (!moved &&
            oldCredential != null &&
            servers.any((saved) => saved.id == profile.id)) {
          await vault.write(updated.credentialKey, oldCredential);
        } else {
          await vault.delete(updated.credentialKey);
        }
      }
      rethrow;
    }
    if (moved) {
      try {
        await vault.delete(profile.credentialKey);
      } on Exception {
        // The new profile already refers only to the independently saved key.
      }
    }
    if (repository?.profile.id == profile.id) {
      await _activate(updated);
    } else {
      settingsChanged();
    }
  }

  Future<void> activate(
    ServerProfile profile, {
    String? authenticationReason,
  }) async {
    final saved = _savedServer(profile.id);
    if (saved.isProtected) {
      final previous = _selection;
      await _requireDeviceAccess(
        authenticationReason ?? 'Authenticate to open this server.',
      );
      if (_selection != previous) return;
    }
    await _activate(_savedServer(profile.id));
  }

  Future<void> _activate(ServerProfile profile) async {
    final generation = ++_selection;
    final credential = await vault.read(profile.credentialKey);
    if (generation != _selection) return;
    if (credential == null) {
      throw const ApiFailure(
        'Saved credentials are unavailable. Sign in to this server again.',
      );
    }
    backgroundDownloads.attach(null);
    await repository?.stopDownloadWork();
    if (generation != _selection) return;
    if (profile.isKindle) {
      KindleSession session;
      try {
        session = KindleSession(object(jsonDecode(credential)));
      } catch (_) {
        throw const KindleFailure('session_invalid');
      }
      if (session.id != profile.id) {
        throw const KindleFailure('account_identity');
      }
      Future<void> save(KindleSession value) async {
        if (!store.accountRemoved(profile.id)) {
          await vault.write(profile.id, jsonEncode(value.json));
        }
      }

      final client =
          kindleClientFactory?.call(session, save) ??
          KindleClient(session: session, saveSession: save);
      repository = KindleRepository(
        profile: profile,
        store: store,
        directory: directory,
        client: client,
      );
    } else {
      repository = Repository(
        profile: profile,
        api: _api(Uri.parse(profile.url), profile.authentication, credential),
        store: store,
        directory: directory,
      );
    }
    if (!standaloneReader) store.setSetting('activeServer', profile.id);
    startupError = null;
    repository!.offline = store.setting<bool>('offline:${profile.id}') == true;
    if (!standaloneReader) backgroundDownloads.attach(repository);
    if (!repository!.offline) {
      if (!standaloneReader) repository!.listen();
      unawaited(repository!.sync());
    }
    notifyListeners();
  }

  Future<void> remove(ServerProfile profile) async {
    final saved = _savedServer(profile.id);
    if (repository?.profile.id == profile.id) {
      _selection++;
      backgroundDownloads.attach(null);
      await repository?.stopDownloadWork();
      repository = null;
    }
    // Tombstone first: a worker already running cannot recreate this account.
    store.removeServer(profile.id);
    await backgroundDownloads.removeProfile(profile.id);
    await vault.delete(saved.credentialKey);
    // Running engines observe the tombstone, abort their streams, and release.
    // A crashed process loses its bounded lease after at most 30 seconds.
    while (store.accountTransferring(profile.id)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final dir = Directory(p.join(directory.path, profile.id));
    if (await dir.exists()) await dir.delete(recursive: true);
    settingsChanged();
  }

  Future<void> connectKindle(KindleSession session) async {
    final profile = ServerProfile(
      id: session.id,
      name: 'Kindle',
      url: 'https://www.amazon.it',
      email: 'Amazon.it',
      authentication: Authentication.apiKey,
      source: 'kindle',
    );
    await vault.write(profile.id, jsonEncode(session.json));
    store.saveServer(profile);
    store.setSetting('offline:${profile.id}', false);
    await activate(profile);
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
