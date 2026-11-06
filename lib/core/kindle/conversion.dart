import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'client.dart';

abstract class KindlePreparation {
  Future<Json> prepare(Directory directory, {Future<void>? abortTrigger});
}

class NativeKindlePreparation implements KindlePreparation {
  static const channel = MethodChannel('dev.levalue.kmreader/kindle');
  static String? executableOverride;
  static String get executable =>
      executableOverride ??
      p.join(
        p.dirname(Platform.resolvedExecutable),
        'kindle',
        'KMReader-Kindle.exe',
      );
  static Future<Json> _worker(
    List<String> arguments, {
    Future<void>? abortTrigger,
  }) async {
    if (!await File(executable).exists()) {
      throw const KindleFailure('kindle_runtime_missing');
    }
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    unawaited(process.stderr.drain<void>());
    var aborted = false;
    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then((_) {
          aborted = true;
          process.kill();
        }),
      );
    }
    var timedOut = false;
    final timeout = Timer(const Duration(minutes: 12), () {
      timedOut = true;
      process.kill();
    });
    try {
      final chunks = StringBuffer();
      await for (final chunk in process.stdout.transform(utf8.decoder)) {
        if (chunks.length + chunk.length > 1024 * 1024) {
          process.kill();
          throw const KindleFailure('worker_response_size');
        }
        chunks.write(chunk);
      }
      final code = await process.exitCode;
      if (aborted) throw const KindleFailure('cancelled');
      if (timedOut) throw const KindleFailure('worker_timeout');
      try {
        final response = object(jsonDecode(chunks.toString()));
        if (code != 0 || response['ok'] != true) {
          final reason = text(
            object(response['error'])['code'],
            text(
              object(response['preparation'])['reason'],
              'conversion_unsupported',
            ),
          );
          // Accept only local protocol category characters, never third-party text.
          throw KindleFailure(
            RegExp(r'^[a-z_]{1,64}$').hasMatch(reason)
                ? reason
                : 'worker_response',
          );
        }
        return response;
      } on KindleFailure {
        rethrow;
      } catch (_) {
        throw const KindleFailure('worker_response');
      }
    } finally {
      timeout.cancel();
    }
  }

  static Future<KindleSession> connectWindows(
    Directory directory, {
    bool importExisting = false,
    Future<void>? abortTrigger,
  }) async {
    final working = Directory(p.join(directory.path, 'kindle-login'));
    final response = await _worker([
      '--data-dir',
      working.path,
      'connect-json',
      if (importExisting) '--import-existing',
    ], abortTrigger: abortTrigger);
    return KindleSession(object(response['session']));
  }

  @override
  Future<Json> prepare(
    Directory directory, {
    Future<void>? abortTrigger,
  }) async {
    Json result;
    if (Platform.isWindows) {
      result = await _worker([
        'prepare-json',
        directory.absolute.path,
      ], abortTrigger: abortTrigger);
    } else if (Platform.isAndroid) {
      if (abortTrigger != null) {
        unawaited(
          abortTrigger.then((_) async {
            try {
              await channel.invokeMethod<void>('cancel', {
                'directory': directory.absolute.path,
              });
            } on PlatformException {
              /* Worker may already have stopped. */
            }
          }),
        );
      }
      try {
        final value = await channel.invokeMethod<String>('prepare', {
          'directory': directory.absolute.path,
        });
        result = object(jsonDecode(value ?? '{}'));
      } on PlatformException catch (error) {
        throw KindleFailure(
          error.code == 'cancelled' ? 'cancelled' : 'conversion_unsupported',
        );
      }
      if (result['ok'] != true) {
        throw KindleFailure(
          text(object(result['error'])['code'], 'conversion_unsupported'),
        );
      }
    } else {
      throw const KindleFailure('platform_unsupported');
    }
    final prepared = object(result['preparation']);
    if (!const {'ready.epub', 'ready.pdf'}.contains(prepared['file']) ||
        !const {'epub', 'pdf'}.contains(prepared['format'])) {
      throw const KindleFailure('worker_file');
    }
    final output = File(p.join(directory.path, prepared['file']));
    if (!await output.exists() || await output.length() == 0) {
      throw const KindleFailure('worker_file');
    }
    return prepared;
  }
}
