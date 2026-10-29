import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Export a completed private file through the platform's document chooser.
/// The caller retains ownership of the source and removes it afterwards.
Future<bool> exportServerLog(File source) async {
  if (Platform.isAndroid) {
    return await const MethodChannel('dev.levalue.kmreader/export')
            .invokeMethod<bool>('exportLog', {'path': source.path}) ??
        false;
  }
  final location = await getSaveLocation(
    suggestedName: 'komga-server.log',
    acceptedTypeGroups: [
      const XTypeGroup(label: 'Log', extensions: ['log', 'txt']),
    ],
  );
  if (location == null) return false;
  await source.copy(location.path);
  return true;
}
