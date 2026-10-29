import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:kmreader/core/api.dart';
import 'package:kmreader/core/app_controller.dart';
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

void main() {
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
