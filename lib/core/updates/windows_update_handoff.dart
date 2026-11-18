import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Wait for the helper to read the job and acquire the application handle.
/// It cannot replace files until the application explicitly commits the job.
Future<void> prepareWindowsUpdate(File script, File job) async {
  final ready = File('${job.path}.ready');
  final failed = File('${job.path}.result');
  // On Windows the normal launch supplies valid standard handles and creates
  // no console window. It also lets us detect an early PowerShell exit.
  final helper = await Process.start(
    p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    ),
    [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '-JobFile',
      job.path,
    ],
    workingDirectory: job.parent.path,
  );
  unawaited(helper.stdin.close());
  unawaited(helper.stdout.drain<void>());
  unawaited(helper.stderr.drain<void>());
  int? exitCode;
  unawaited(helper.exitCode.then((code) => exitCode = code));
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 15)) {
    if (exitCode != null || await failed.exists()) break;
    if (await ready.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw ProcessException(
    'Windows update helper',
    const [],
    'Helper not ready',
    exitCode ?? 0,
  );
}

Future<void> commitWindowsUpdate(File job) =>
    File('${job.path}.commit').create();
