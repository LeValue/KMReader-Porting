import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Export a completed private file through the platform's document chooser.
/// The caller retains ownership of the source and removes it afterwards.
Future<bool> exportServerLog(
  File source, {
  String suggestedName = 'komga-server.log',
}) async {
  if (Platform.isAndroid) {
    return await const MethodChannel('dev.levalue.kmreader/export')
            .invokeMethod<bool>('exportLog', {
              'path': source.path,
              'name': suggestedName,
            }) ??
        false;
  }
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: [
      const XTypeGroup(label: 'Log', extensions: ['log', 'txt']),
    ],
  );
  if (location == null) return false;
  await source.copy(location.path);
  return true;
}
