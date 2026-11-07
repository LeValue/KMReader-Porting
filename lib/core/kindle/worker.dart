import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'client.dart';

/// A reusable, bounded converter process. Only local paths and temporary
/// content URLs enter its private stdin; account credentials never do.
class KindleWorker {
  KindleWorker(this.executable);
  final String executable;
  Process? _process;
  StreamIterator<String>? _lines;
  final _queue = <_Job>[];
  bool _running = false;
  Timer? _idle;
  int _id = 0;

  Future<Json> call(Json request, {Future<void>? abortTrigger}) {
    final job = _Job(request, abortTrigger);
    if (request['operation'] == 'prepare') {
      _queue.insert(0, job);
    } else {
      _queue.add(job);
    }
    _idle?.cancel();
    unawaited(_pump());
    return job.result.future;
  }

  Future<void> _stop() async {
    final process = _process;
    _process = null;
    final lines = _lines;
    _lines = null;
    process?.kill();
    await lines?.cancel();
    if (process != null) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      var aborted = false, active = true;
      if (job.abort != null) {
        unawaited(
          job.abort!.then((_) {
            aborted = true;
            if (active) unawaited(_stop());
          }),
        );
      }
      try {
        if (_process == null) {
          if (!await File(executable).exists()) {
            throw const KindleFailure('kindle_runtime_missing');
          }
          final process = await Process.start(executable, ['rpc-json']);
          _process = process;
          unawaited(process.stderr.drain<void>());
          _lines = StreamIterator(
            process.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter()),
          );
        }
        if (aborted) throw const KindleFailure('cancelled');
        final identifier = ++_id;
        _process!.stdin.writeln(jsonEncode({'id': identifier, ...job.request}));
        await _process!.stdin.flush();
        final received = await _lines!.moveNext().timeout(
          const Duration(minutes: 12),
        );
        if (aborted) throw const KindleFailure('cancelled');
        if (!received || _lines!.current.length > 1024 * 1024) {
          throw const KindleFailure('worker_response');
        }
        final response = object(jsonDecode(_lines!.current));
        if (response['id'] != identifier) {
          throw const KindleFailure('worker_response');
        }
        if (response['ok'] != true) {
          final reason = text(
            object(response['preparation'])['reason'],
            text(object(response['error'])['code']),
          );
          throw KindleFailure(
            RegExp(r'^[a-z_]{1,64}$').hasMatch(reason)
                ? reason
                : 'worker_response',
          );
        }
        job.result.complete(response);
      } catch (error, stack) {
        await _stop();
        job.result.completeError(
          aborted
              ? const KindleFailure('cancelled')
              : error is KindleFailure
              ? error
              : const KindleFailure('worker_response'),
          stack,
        );
      } finally {
        active = false;
      }
    }
    _running = false;
    _idle = Timer(const Duration(seconds: 20), () => unawaited(_stop()));
  }
}

class _Job {
  _Job(this.request, this.abort);
  final Json request;
  final Future<void>? abort;
  final result = Completer<Json>();
}
