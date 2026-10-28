import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'download_policy.dart';
import 'download_worker.dart';
import 'models.dart';
import 'repository.dart';
import 'store.dart';

final _workers = <String, DownloadWorker>{};

@pragma('vm:entry-point')
void downloadCallbackDispatcher() {
  Workmanager().executeTask(
    (task, input) async {
      if (input == null || !task.startsWith('kmreader-download:')) return true;
      final directory = input['directory'],
          server = input['server'],
          book = input['book'];
      if (directory is! String || server is! String || book is! String) {
        return true;
      }
      final worker = DownloadWorker(
        directory: Directory(directory),
        server: server,
        book: book,
      );
      _workers[task] = worker;
      try {
        return await worker.run();
      } catch (_) {
        return false;
      } finally {
        _workers.remove(task);
      }
    },
    onTaskStopped: (task, _) async {
      await _workers[task]?.stop();
    },
  );
}

/// Restores durable OS work after startup and keeps foreground transfers under
/// the same network/power rules. Native jobs contain no API keys or passwords.
class BackgroundDownloads with WidgetsBindingObserver {
  BackgroundDownloads(this.store, this.directory);
  final LocalStore store;
  final Directory directory;
  static const channel = MethodChannel('dev.levalue.kmreader/background');
  final _known = <String>{};
  final _windowsProfiles = <String>{};
  Repository? _repository;
  TransferConditions _conditions = const TransferConditions();
  Timer? _debounce;
  Timer? _poll;
  Future<void> _serial = Future.value();
  bool _disposed = false;
  bool _initialized = false;
  bool _reset = false;
  int? _externalRevision;
  String? failure;
  DownloadPolicy get policy => DownloadPolicy.read(store);
  bool get supported => Platform.isAndroid || Platform.isWindows;

  static String profileTag(String id) =>
      'kmreader-${sha256.convert(utf8.encode(id))}';
  static String jobId(String server, String book) =>
      '${profileTag(server)}-${sha256.convert(utf8.encode(book))}';

  Future<void> initialize() async {
    if (!supported) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      await Workmanager().initialize(downloadCallbackDispatcher);
    }
    channel.setMethodCallHandler((call) async {
      if (call.method == 'conditions') {
        _conditions = TransferConditions.parse(object(call.arguments));
        _applyConditions();
      }
    });
    await _readConditions();
    // Also notices another engine's persisted fractions/completion/cancellation.
    _externalRevision = store.externalRevision;
    _poll = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timer.tick % 5 == 0) unawaited(_readConditions());
      final revision = store.externalRevision;
      if (revision != _externalRevision) {
        _externalRevision = revision;
        _repository?.changed();
        refresh();
      }
    });
    refresh();
  }

  void attach(Repository? repository) {
    _repository?.onDownloadQueueChanged = null;
    _repository?.canTransfer = null;
    _repository = repository;
    if (repository != null) {
      repository.onDownloadQueueChanged = refresh;
      repository.canTransfer = () => policy.permits(_conditions);
      _applyConditions();
    }
    refresh();
  }

  void setPolicy(DownloadPolicy value) {
    store.setSetting('downloadPolicy', value.toJson());
    _reset = true;
    _applyConditions();
    refresh();
  }

  void _applyConditions() {
    final repository = _repository;
    if (repository == null) return;
    if (policy.permits(_conditions) && !repository.offline) {
      repository.resumeDownloads();
    } else {
      repository.pauseDownloads();
    }
  }

  Future<void> _readConditions() async {
    if (_disposed || !supported) return;
    try {
      final value = await channel.invokeMapMethod<String, dynamic>(
        'conditions',
      );
      if (_disposed || value == null) return;
      final next = TransferConditions.parse(value);
      if (next.connected != _conditions.connected ||
          next.metered != _conditions.metered ||
          next.charging != _conditions.charging) {
        _conditions = next;
        _applyConditions();
      }
    } on MissingPluginException {
      // Injectable controllers/widget tests have no native host.
    } on PlatformException {
      // A later connectivity/power event or foreground poll retries the probe.
    }
  }

  void refresh() {
    if (_disposed || !supported || !_initialized) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      _serial = _serial.then((_) => _reconcile()).catchError((Object error) {
        failure = error.toString();
      });
    });
  }

  Future<void> _reconcile() async {
    if (_disposed) return;
    final currentPolicy = policy;
    final reset = _reset;
    _reset = false;
    final wanted = <String>{};
    final windowsWanted = <String>{};
    for (final profile in store.servers) {
      final enabled =
          currentPolicy.background &&
          store.setting<bool>('offline:${profile.id}') != true;
      final rows = store.downloads(profile.id);
      final pending = rows
          .where(
            (row) =>
                ['queued', 'downloading', 'paused'].contains(row['status']) ||
                (row['status'] == 'failed' &&
                    _known.contains(
                      jobId(profile.id, Book(object(row['book'])).id),
                    )),
          )
          .toList();
      if (Platform.isWindows) {
        if (enabled && pending.isNotEmpty) {
          windowsWanted.add(profile.id);
          {
            await channel.invokeMethod('schedule', {
              'id': profileTag(profile.id),
              'directory': directory.path,
              'server': profile.id,
              'charging': currentPolicy.charging,
              'unmetered': currentPolicy.unmetered,
            });
          }
        }
        continue;
      }
      if (!enabled) await Workmanager().cancelByTag(profileTag(profile.id));
      for (final row in pending) {
        if (!enabled) break;
        final book = Book(object(row['book']));
        final id = jobId(profile.id, book.id);
        wanted.add(id);
        if (reset || !_known.contains(id)) {
          await Workmanager().registerOneOffTask(
            id,
            'kmreader-download:$id:${DateTime.now().microsecondsSinceEpoch}',
            inputData: {
              'directory': directory.path,
              'server': profile.id,
              'book': book.id,
            },
            initialDelay: const Duration(seconds: 5),
            constraints: Constraints(
              networkType: currentPolicy.unmetered
                  ? NetworkType.unmetered
                  : NetworkType.connected,
              requiresCharging: currentPolicy.charging,
            ),
            existingWorkPolicy: reset
                ? ExistingWorkPolicy.replace
                : ExistingWorkPolicy.keep,
            backoffPolicy: BackoffPolicy.exponential,
            backoffPolicyDelay: const Duration(seconds: 30),
            tag: profileTag(profile.id),
          );
        }
      }
    }
    for (final id in _known.difference(wanted)) {
      await Workmanager().cancelByUniqueName(id);
    }
    for (final id in _windowsProfiles.difference(windowsWanted)) {
      await channel.invokeMethod('cancel', profileTag(id));
    }
    _known
      ..clear()
      ..addAll(wanted);
    _windowsProfiles
      ..clear()
      ..addAll(windowsWanted);
    failure = null;
  }

  Future<void> removeProfile(String id) async {
    if (!supported || !_initialized) return;
    await _serial;
    if (Platform.isAndroid) {
      await Workmanager().cancelByTag(profileTag(id));
    } else {
      await channel.invokeMethod('cancel', profileTag(id));
    }
    _known.removeWhere((key) => key.startsWith(profileTag(id)));
    _windowsProfiles.remove(id);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_readConditions());
      refresh();
    }
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _poll?.cancel();
    if (supported && _initialized) {
      WidgetsBinding.instance.removeObserver(this);
      channel.setMethodCallHandler(null);
    }
    _repository?.onDownloadQueueChanged = null;
  }
}

/// Called by a hidden Windows engine; each executable Dart root exports a
/// small entry point forwarding here (including native integration targets).
Future<void> runWindowsDownloadWorker(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.length != 3 || arguments.first != '--background-downloads') {
    exit(2);
  }
  var success = false;
  try {
    success = await DownloadWorker(
      directory: Directory(arguments[1]),
      server: arguments[2],
      budget: const Duration(minutes: 50),
      conditions: () async => TransferConditions.parse(
        object(await BackgroundDownloads.channel.invokeMethod('conditions')),
      ),
    ).run();
  } catch (_) {
    success = false;
  }
  exit(success ? 0 : 1);
}
