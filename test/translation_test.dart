import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/core/translation.dart';
import 'package:sqlite3/sqlite3.dart';

class Vault implements CredentialVault {
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

const provider = TranslationProvider(
  id: 'fixture',
  name: 'Fixture',
  base: 'https://provider.example.invalid/v1',
  model: 'fixture-model',
);
void main() {
  test('provider keys stay in the vault; edits preserve keys and deletion removes them', () async {
    final store = LocalStore(sqlite3.openInMemory());
    addTearDown(store.close);
    final vault = Vault(),
        providers = TranslationProviders(store, vault: vault);
    await providers.save(
      name: 'Fixture',
      base: provider.base,
      model: provider.model,
      apiKey: 'fixture-secret',
    );
    final saved = providers.values.single;
    expect(await providers.key(saved.id), 'fixture-secret');
    expect(
      store.db
          .select('SELECT value FROM settings')
          .any((r) => (r['value'] as String).contains('fixture-secret')),
      false,
    );
    await providers.save(
      original: saved,
      name: 'Renamed',
      base: saved.base,
      model: 'new-model',
      apiKey: '',
    );
    expect(await providers.key(saved.id), 'fixture-secret');
    await providers.remove(providers.active!);
    expect(vault.values, isEmpty);
    expect(providers.values, isEmpty);
  });
  test('model catalog and batched translations validate IDs and restore source ordering', () async {
    var batches = 0;
    final client = TranslationClient(
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer fixture-secret');
        expect(request.followRedirects, false);
        expect(request.url.origin, 'https://provider.example.invalid');
        if (request.url.path.endsWith('/models')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'b', 'name': 'Beta'},
                {'id': 'a', 'name': 'Alpha'},
              ],
            }),
            200,
          );
        }
        batches++;
        final body = jsonDecode(request.body) as Map;
        expect(body['model'], 'fixture-model');
        final payload = jsonDecode(body['messages'][1]['content']) as Map;
        final segments = payload['segments'] as List;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'translations': segments.reversed
                        .map(
                          (s) => {'id': s['id'], 'text': 'Tradotto ${s['id']}'},
                        )
                        .toList(),
                  }),
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);
    expect((await client.models(provider, 'fixture-secret')).first['id'], 'a');
    final translated = await client.translate(
      provider,
      'fixture-secret',
      List.generate(35, (i) => 'Text $i'),
      source: 'en',
      target: 'it',
    );
    expect(batches, 2);
    expect(translated, List.generate(35, (i) => 'Tradotto $i'));
  });
  test(
    'invalid provider responses and redirects never become translations',
    () async {
      for (final payload in [
        {
          'translations': [
            {'id': 0, 'text': 'a'},
            {'id': 0, 'text': 'b'},
          ],
        },
        {
          'translations': [
            {'id': 1, 'text': 'Wrong ID'},
          ],
        },
        {'translations': []},
      ]) {
        final client = TranslationClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': jsonEncode(payload)},
                  },
                ],
              }),
              200,
            ),
          ),
        );
        await expectLater(
          client.translate(
            provider,
            null,
            ['Text'],
            source: 'auto',
            target: 'it',
          ),
          throwsFormatException,
        );
        client.close();
      }
      final redirected = TranslationClient(
        client: MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {'location': 'https://another.example.invalid'},
          ),
        ),
      );
      addTearDown(redirected.close);
      await expectLater(
        redirected.models(provider, 'fixture-secret'),
        throwsStateError,
      );
    },
  );
  test('translation cache distinguishes model/language and private requests persist nothing', () async {
    final dir = Directory.systemTemp.createTempSync('translation-cache-');
    addTearDown(() => dir.deleteSync(recursive: true));
    var calls = 0;
    final client = TranslationClient(
      client: MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': '{"translations":[{"id":0,"text":"Ciao"}]}',
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);
    final cache = TranslationCache(dir, client);
    await cache.translate(
      provider,
      null,
      ['Hello'],
      source: 'en',
      target: 'it',
    );
    await cache.translate(
      provider,
      null,
      ['Hello'],
      source: 'en',
      target: 'it',
    );
    expect(calls, 1);
    await cache.translate(
      provider,
      null,
      ['Hello'],
      source: 'en',
      target: 'fr',
      cache: false,
    );
    expect(calls, 2);
    expect(dir.listSync(recursive: true).whereType<File>(), hasLength(1));
  });
}
