import 'dart:io';

import 'package:path/path.dart' as p;

/// Wait for the helper to read the job and acquire the application handle.
/// It cannot replace files until the application explicitly commits the job.
Future<void> prepareWindowsUpdate(File script, File job) async {
  final ready = File('${job.path}.ready');
  final failed = File('${job.path}.result');
  await Process.start(
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
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '-JobFile',
      job.path,
    ],
    workingDirectory: job.parent.path,
    mode: ProcessStartMode.detached,
  );
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 15)) {
    if (await failed.exists()) break;
    if (await ready.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw const ProcessException('Windows update helper', [], 'Helper not ready');
}

Future<void> commitWindowsUpdate(File job) =>
    File('${job.path}.commit').create();
