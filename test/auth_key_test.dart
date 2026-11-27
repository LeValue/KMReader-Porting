import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/device_lock.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';

class _Vault implements CredentialVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class _Authenticator implements DeviceAuthenticator {
  bool allow = true;
  int challenges = 0;
  @override
  Future<bool> supported() async => true;
  @override
  Future<bool> authenticate(String reason) async {
    challenges++;
    return allow;
  }
}

void main() {
  group('saved server changes', () {
    late Directory directory;
    late LocalStore store;
    late _Vault vault;
    late _Authenticator authenticator;
    late AppController app;
    late ServerProfile profile;
    late List<http.Request> requests;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('edit-server-');
      store = LocalStore(sqlite3.openInMemory());
      vault = _Vault();
      authenticator = _Authenticator();
      requests = [];
      final uri = Uri.parse('https://saved.invalid');
      profile = ServerProfile(
        id: ServerProfile.identity(uri, 'member'),
        name: 'Before',
        url: uri.toString(),
        email: 'member@example.invalid',
        authentication: Authentication.apiKey,
        apiKeyId: 'known',
        managedKey: true,
        userId: 'member',
      );
      store.saveServer(profile);
      store.setSetting('offline:${profile.id}', true);
      vault.values[profile.id] = 'saved-key';
      app = AppController(
        store: store,
        directory: directory,
        vault: vault,
        deviceAuthenticator: authenticator,
        apiFactory: (base, auth, input) => KomgaApi(
          base,
          authentication: auth,
          credential: input,
          client: MockClient((request) async {
            requests.add(request);
            return http.Response(
              jsonEncode({
                'id': input == 'wrong-user' ? 'other' : 'member',
                'email': 'member@example.invalid',
                'roles': ['ADMIN'],
              }),
              200,
            );
          }),
        ),
      );
    });

    tearDown(() {
      app.disconnect();
      app.deviceLock.dispose();
      app.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    });

    test('rename preserves the key identity and works offline', () async {
      await app.activate(profile);
      await app.updateServer(
        profile,
        name: 'After',
        isProtected: false,
        authenticationReason: 'Edit server',
      );
      final saved = store.servers.single;
      expect(saved.id, profile.id);
      expect(saved.name, 'After');
      expect(saved.apiKeyId, 'known');
      expect(vault.values[profile.id], 'saved-key');
      expect(app.repository!.profile.name, 'After');
      expect(app.repository!.offline, isTrue);
      expect(requests, isEmpty);
    });

    test(
      'moving a server verifies the new address and preserves downloaded books',
      () async {
        final book = Book({'id': 'volume', 'name': 'Example.cbz'});
        store.saveDownload(profile.id, book, 'ready', size: 100);
        await app.activate(profile);
        final savedFile = app.repository!.bookFile(book);
        await savedFile.parent.create(recursive: true);
        await savedFile.writeAsString('original');
        Future<void> move({String? secret}) => app.updateServer(
          profile,
          name: 'Moved',
          address: 'https://moved.invalid/',
          isProtected: false,
          authenticationReason: 'Edit server',
          secret: secret,
        );
        await expectLater(move(), throwsA(isA<ApiFailure>()));
        expect(requests, isEmpty);
        await expectLater(
          move(secret: 'wrong-user'),
          throwsA(isA<ApiFailure>()),
        );
        expect(store.servers.single.url, profile.url);
        expect(vault.values[profile.id], 'saved-key');
        await move(secret: 'replacement');

        final moved = store.servers.single;
        expect(moved.id, profile.id);
        expect(moved.url, 'https://moved.invalid');
        expect(moved.credentialKey, isNot(profile.credentialKey));
        expect(vault.values, {moved.credentialKey: 'replacement'});
        expect(
          requests.map((request) => request.url.host),
          everyElement('moved.invalid'),
        );
        expect(app.repository!.bookFile(book).path, savedFile.path);
        expect(await savedFile.readAsString(), 'original');
        expect(store.download(profile.id, book.id)?['status'], 'ready');

        final signedIn = await app.login(
          address: moved.url,
          name: moved.name,
          authentication: Authentication.apiKey,
          username: '',
          password: 'replacement',
        );
        expect(store.servers, hasLength(1));
        expect(signedIn.id, moved.id);
        expect(signedIn.credentialKey, moved.credentialKey);
      },
    );

    test(
      'replacement requires the same account and clears an old key id',
      () async {
        await expectLater(
          app.updateServer(
            profile,
            name: 'Before',
            isProtected: false,
            authenticationReason: 'Edit server',
            secret: 'wrong-user',
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(vault.values[profile.id], 'saved-key');
        expect(store.servers.single.apiKeyId, 'known');
        await app.updateServer(
          profile,
          name: 'Before',
          isProtected: false,
          authenticationReason: 'Edit server',
          secret: 'replacement',
        );
        final saved = store.servers.single;
        expect(saved.id, profile.id);
        expect(saved.apiKeyId, isNull);
        expect(saved.admin, isTrue);
        expect(vault.values[profile.id], 'replacement');
        expect(requests.last.headers['X-API-Key'], 'replacement');
      },
    );

    test('protected servers stay hidden and a stale record cannot bypass authentication', () async {
      await app.updateServer(
        profile,
        name: 'Private',
        isProtected: true,
        authenticationReason: 'Protect server',
      );
      expect(store.servers.single.isProtected, isTrue);
      expect(app.visibleServers, isEmpty);
      authenticator.allow = false;
      await expectLater(app.activate(profile), throwsA(isA<ApiFailure>()));
      expect(app.repository, isNull);
      await expectLater(
        app.chooseProtectedServer('Open protected servers', (_) async {
          fail('The protected list must stay private after denial');
        }),
        throwsA(isA<ApiFailure>()),
      );
      authenticator.allow = true;
      final before = authenticator.challenges;
      await app.chooseProtectedServer('Open protected servers', (
        profiles,
      ) async {
        expect(profiles.single.name, 'Private');
        expect(app.protectedServerVisible, isTrue);
        return profiles.single;
      });
      expect(authenticator.challenges, before + 1);
      expect(app.repository?.profile.isProtected, isTrue);
    });
  });
  for (final mode in ['verified', 'unsupported', 'invalid', 'optOut']) {
    test('automatic API key login: $mode', () async {
      final directory = Directory.systemTemp.createTempSync('auth-key-');
      final store = LocalStore(sqlite3.openInMemory());
      final serverId = ServerProfile.identity(
        Uri.parse('https://example.invalid'),
        'user',
      );
      store.setSetting('offline:$serverId', true);
      final vault = _Vault();
      final requests = <http.Request>[];
      final app = AppController(
        store: store,
        directory: directory,
        vault: vault,
        apiFactory: (base, auth, credential) => KomgaApi(
          base,
          authentication: auth,
          credential: credential,
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('/api-keys') &&
                request.method == 'POST') {
              return mode == 'unsupported'
                  ? http.Response('', 404)
                  : http.Response(
                      jsonEncode({
                        'id': 'generated',
                        'key': 'synthetic-device-key',
                      }),
                      200,
                    );
            }
            if (request.method == 'DELETE') return http.Response('', 204);
            if (request.url.path.endsWith('/users/me')) {
              final key = request.headers['X-API-Key'];
              if (key != null) {
                expect(key, 'synthetic-device-key');
                expect(request.headers.containsKey('Authorization'), isFalse);
              }
              return http.Response(
                jsonEncode({
                  'id': mode == 'invalid' && key != null
                      ? 'wrong-account'
                      : 'user',
                  'email': 'test@example.invalid',
                  'roles': ['ADMIN'],
                }),
                200,
              );
            }
            return http.Response('', 204);
          }),
        ),
      );
      try {
        final profile = await app.login(
          address: 'https://example.invalid',
          name: 'Test',
          authentication: Authentication.password,
          username: 'test@example.invalid',
          password: 'synthetic-password',
          autoCreateApiKey: mode != 'optOut',
        );
        expect(
          profile.authentication,
          mode == 'verified' ? Authentication.apiKey : Authentication.password,
        );
        expect(profile.apiKeyId, mode == 'verified' ? 'generated' : null);
        expect(profile.managedKey, mode == 'verified');
        expect(app.repository!.offline, false);
        expect(store.setting<bool>('offline:$serverId'), false);
        expect(
          vault.values[profile.id],
          mode == 'verified'
              ? 'synthetic-device-key'
              : base64Encode(
                  utf8.encode('test@example.invalid:synthetic-password'),
                ),
        );
        expect(
          jsonEncode(store.servers.single.toJson()),
          isNot(contains('synthetic-password')),
        );
        expect(
          jsonEncode(store.servers.single.toJson()),
          isNot(contains('synthetic-device-key')),
        );
        expect(requests.any((r) => r.method == 'DELETE'), mode == 'invalid');
        if (mode == 'optOut') {
          expect(requests.any((r) => r.method == 'POST'), isFalse);
        }
      } finally {
        app.disconnect();
        app.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      }
    });
  }
}
