import 'dart:convert';
import 'dart:io';

import '../lib/core/updates/windows_update_handoff.dart';

// The updater must survive this process exiting, just as it does in the app.
Future<void> main(List<String> args) async {
  final script = File(args[0]);
  final job = File(args[1]);
  final data = jsonDecode(await job.readAsString()) as Map<String, dynamic>;
  await job.writeAsString(jsonEncode({...data, 'pid': pid}), flush: true);
  await prepareWindowsUpdate(script, job);
  if (args.contains('--cancel')) return;
  await commitWindowsUpdate(job);
}
