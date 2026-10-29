import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

class _Vault implements CredentialVault {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    if (failWrites) throw StateError('Synthetic vault failure');
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

void main() {
  late Directory directory;
  late LocalStore store;
  late _Vault vault;
  late AppController app;
  late String remotePassword;
  late Future<http.Response> Function(http.Request) update;
  final requests = <http.Request>[];
  String token(String password) =>
      base64Encode(utf8.encode('reader@example.invalid:$password'));
  setUp(() {
    directory = Directory.systemTemp.createTempSync('password-test-');
    store = LocalStore(sqlite3.openInMemory());
    vault = _Vault();
    remotePassword = 'old-secret';
    requests.clear();
    update = (request) async {
      remotePassword = object(jsonDecode(request.body))['password'];
      return http.Response('', 204);
    };
    app = AppController(
      store: store,
      directory: directory,
      vault: vault,
      apiFactory: (base, auth, credential) => KomgaApi(
        base,
        authentication: auth,
        credential: credential,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/users/me')) {
            if (auth == Authentication.password &&
                credential != token(remotePassword)) {
              return http.Response('', 401);
            }
            return http.Response(
              '{"id":"self/1","email":"reader@example.invalid","roles":[]}',
              200,
            );
          }
          if (request.method == 'PATCH') return update(request);
          return http.Response('', 204);
        }),
      ),
    );
  });
  tearDown(() async {
    await app.repository?.stopDownloadWork();
    app.disconnect();
    app.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });
  Future<ServerProfile> login([
    Authentication method = Authentication.password,
  ]) => app.login(
    address: 'https://example.invalid/base',
    name: 'Fixture',
    authentication: method,
    username: 'reader@example.invalid',
    password: method == Authentication.password
        ? 'old-secret'
        : 'synthetic-key',
    autoCreateApiKey: false,
  );

  test('password change preserves identity, replaces only vaulted basic credentials and reconnects', () async {
    final profile = await login();
    final old = app.repository!;
    await app.changePassword(old, 'new-secret');
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(patch.url.pathSegments, [
      'base',
      'api',
      'v2',
      'users',
      'self/1',
      'password',
    ]);
    expect(jsonDecode(patch.body), {'password': 'new-secret'});
    expect(remotePassword, 'new-secret');
    expect(vault.values[profile.id], token('new-secret'));
    expect(app.repository!.profile.id, profile.id);
    expect(old.closed, true);
    expect(await app.repository!.api.user(), containsPair('id', 'self/1'));
    expect(
      store.db.select('SELECT * FROM settings').toString(),
      isNot(contains('new-secret')),
    );
    expect(
      store.servers.single.toJson().toString(),
      isNot(contains('new-secret')),
    );
  });
  test('API key authentication stays active and does not replace the key with a password', () async {
    final profile = await login(Authentication.apiKey);
    final original = app.repository!;
    await app.changePassword(original, 'new-secret');
    expect(remotePassword, 'new-secret');
    expect(vault.values[profile.id], 'synthetic-key');
    expect(identical(app.repository, original), true);
    expect(original.closed, false);
  });
  test('rejected and offline changes preserve the old credential and are not retried', () async {
    final profile = await login();
    update = (_) async => http.Response('', 403);
    await expectLater(
      app.changePassword(app.repository!, 'new-secret'),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
    );
    expect(vault.values[profile.id], token('old-secret'));
    app.repository!.setOffline(true);
    await expectLater(
      app.changePassword(app.repository!, 'new-secret'),
      throwsA(isA<ApiFailure>().having((e) => e.offline, 'offline', true)),
    );
    expect(requests.where((r) => r.method == 'PATCH'), hasLength(1));
  });
  test(
    'a lost response verifies the new password without replaying PATCH',
    () async {
      final profile = await login();
      update = (request) async {
        remotePassword = object(jsonDecode(request.body))['password'];
        throw http.ClientException('Synthetic lost response');
      };
      await app.changePassword(app.repository!, 'new-secret');
      expect(vault.values[profile.id], token('new-secret'));
      expect(requests.where((r) => r.method == 'PATCH'), hasLength(1));
      expect(await app.repository!.api.user(), containsPair('id', 'self/1'));
    },
  );
  test(
    'a failed uncommitted request never overwrites the stored password',
    () async {
      final profile = await login();
      update = (_) async =>
          throw http.ClientException('Synthetic failed request');
      await expectLater(
        app.changePassword(app.repository!, 'new-secret'),
        throwsA(isA<ApiFailure>()),
      );
      expect(vault.values[profile.id], token('old-secret'));
      expect(remotePassword, 'old-secret');
      expect(requests.where((r) => r.method == 'PATCH'), hasLength(1));
    },
  );
  test('vault failure after an applied change requires sign-in without caching the password', () async {
    final profile = await login();
    vault.failWrites = true;
    await expectLater(
      app.changePassword(app.repository!, 'new-secret'),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.message,
          'message',
          startsWith('Password changed.'),
        ),
      ),
    );
    expect(remotePassword, 'new-secret');
    expect(app.repository, isNull);
    expect(vault.values[profile.id], token('old-secret'));
    expect(
      store.db.select('SELECT * FROM settings').toString(),
      isNot(contains('new-secret')),
    );
  });
  test('removing an account during the request cannot recreate its vaulted credentials', () async {
    final profile = await login();
    final gate = Completer<http.Response>();
    update = (_) => gate.future;
    final changed = app.changePassword(app.repository!, 'new-secret');
    await Future<void>.delayed(Duration.zero);
    await app.remove(profile);
    gate.complete(http.Response('', 204));
    await changed;
    expect(store.servers, isEmpty);
    expect(vault.values.containsKey(profile.id), false);
    expect(app.repository, isNull);
  });
  test(
    'an account switch during the request never retargets the selected server',
    () async {
      final profile = await login();
      final gate = Completer<http.Response>();
      update = (_) => gate.future;
      final changed = app.changePassword(app.repository!, 'new-secret');
      await Future<void>.delayed(Duration.zero);
      final other = ServerProfile(
        id: 'other',
        name: 'Other',
        url: 'https://other.invalid',
        email: 'other@example.invalid',
        authentication: Authentication.apiKey,
      );
      store.saveServer(other);
      vault.values[other.id] = 'other-key';
      await app.activate(other);
      gate.complete(http.Response('', 204));
      await changed;
      expect(app.repository!.profile.id, other.id);
      expect(vault.values[profile.id], token('new-secret'));
      expect(vault.values[other.id], 'other-key');
    },
  );
}
