import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import 'api.dart';
import 'credentials.dart';
import 'download_policy.dart';
import 'models.dart';
import 'repository.dart';
import 'store.dart';

/// Owns its database and transport. Input contains identifiers, never secrets.
/// SQLite leases arbitrate with a foreground window or another OS worker.
class DownloadWorker {
  DownloadWorker({
    required this.directory,
    required this.server,
    this.book,
    this.vault = const SecureVault(),
    this.budget = const Duration(minutes: 8),
    this.conditions,
  });
  final Directory directory;
  final String server;
  final String? book;
  final CredentialVault vault;
  final Duration budget;
  final Future<TransferConditions> Function()? conditions;
  Repository? _repository;
  Future<void>? _stopping;
  bool _stopped = false;
  Future<void> stop() async {
    _stopped = true;
    final repository = _repository;
    if (repository != null) {
      await (_stopping ??= repository.stopDownloadWork());
    }
  }

  Future<bool> run() async {
    // A scheduler left behind by a removed installation must not recreate data.
    final database = File(p.join(directory.path, 'kmreader.sqlite'));
    if (!await database.exists()) return true;
    final store = LocalStore(sqlite3.open(database.path));
    Timer? timer;
    Timer? policyCheck;
    String? active;
    bool cancelled() =>
        store.accountRemoved(server) ||
        store.setting<bool>('offline:$server') == true ||
        !DownloadPolicy.read(store).background;
    try {
      final profile = store.servers.where((p) => p.id == server).firstOrNull;
      if (profile == null || cancelled()) return true;
      final credential = await vault.read(server);
      if (_stopped) return false;
      if (credential == null) return true;
      if (conditions != null &&
          !DownloadPolicy.read(store).permits(await conditions!())) {
        return false;
      }
      final repository = _repository = Repository(
        profile: profile,
        api: KomgaApi(
          Uri.parse(profile.url),
          authentication: profile.authentication,
          credential: credential,
        ),
        store: store,
        directory: directory,
        backgroundTransfer: true,
      );
      timer = Timer(budget, () => unawaited(stop()));
      var checking = false;
      policyCheck = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (checking || _stopped) return;
        checking = true;
        try {
          if (cancelled() ||
              (conditions != null &&
                  !DownloadPolicy.read(store).permits(await conditions!()))) {
            await stop();
          }
        } catch (_) {
          await stop();
        } finally {
          checking = false;
        }
      });
      // Windows drains a profile with one process. Android uses one OS job/book.
      for (final row in store.downloads(server)) {
        final item = Book(object(row['book']));
        if (book != null && item.id != book) continue;
        if (![
          'queued',
          'paused',
          'downloading',
          'failed',
        ].contains(row['status'])) {
          continue;
        }
        if (_stopped) return false;
        if (cancelled()) return true;
        active = item.id;
        try {
          await repository.download(item);
        } on TransferBusy {
          return false;
        } catch (error) {
          final current = store.download(server, item.id);
          if (current == null ||
              current['status'] == 'cancelled' ||
              cancelled()) {
            continue;
          }
          final retry = _stopped || retryableTransfer(error);
          if (retry) {
            store.saveDownload(server, item, 'queued');
            return false;
          }
          // Authentication, missing files and storage errors need user action.
        } finally {
          if (_stopped && !cancelled()) {
            final current = store.download(server, item.id);
            if (current != null &&
                [
                  'downloading',
                  'paused',
                  'queued',
                ].contains(current['status'])) {
              store.saveDownload(server, item, 'queued');
            }
          }
          active = null;
        }
      }
      return !_stopped;
    } finally {
      timer?.cancel();
      policyCheck?.cancel();
      await stop();
      assert(active == null);
      store.close();
    }
  }
}

bool retryableTransfer(Object error) =>
    error is SocketException ||
    error is http.ClientException ||
    error is TimeoutException ||
    error is TransferBusy ||
    (error is ApiFailure &&
        (error.retryable ||
            error.offline ||
            error.status == 408 ||
            error.status == 429 ||
            (error.status ?? 0) >= 500));
