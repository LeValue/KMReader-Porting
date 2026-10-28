import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/app_controller.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

class _Vault implements CredentialVault {
  @override
  Future<String?> read(String id) async => 'fixture';
  @override
  Future<void> write(String id, String value) async {}
  @override
  Future<void> delete(String id) async {}
}

void main() {
  test('removing an account waits for active image work before deleting its directory', () async {
    final directory = Directory.systemTemp.createTempSync('account-shutdown-');
    final store = LocalStore(sqlite3.openInMemory());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>();
    server.listen((request) async {
      if (request.uri.path.endsWith('/thumbnail')) {
        request.response.bufferOutput = false;
        request.response.contentLength = 100;
        request.response.add([1, 2]);
        await request.response.flush();
        started.complete();
      } else {
        await request.response.close();
      }
    });
    final profile = ServerProfile(
      id: 'account',
      name: 'Fixture',
      url: 'http://127.0.0.1:${server.port}',
      email: '',
      authentication: Authentication.apiKey,
    );
    store.saveServer(profile);
    final app = AppController(
      store: store,
      directory: directory,
      vault: _Vault(),
    );
    try {
      await app.activate(profile);
      final repository = app.repository!;
      var imageFinished = false;
      final image = repository
          .image('/api/v1/books/one/thumbnail')
          .then<void>(
            (_) {
              imageFinished = true;
            },
            onError: (Object _) {
              imageFinished = true;
            },
          );
      await started.future;
      await app.remove(profile);
      expect(imageFinished, true);
      await image;
      expect(repository.closed, true);
      expect(store.servers, isEmpty);
      expect(
        await Directory('${directory.path}/${profile.id}').exists(),
        false,
      );
    } finally {
      app.disconnect();
      store.close();
      await server.close(force: true);
      directory.deleteSync(recursive: true);
    }
  });
}
