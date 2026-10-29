import 'dart:io';
import 'dart:ui' as ui;

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

/// PNG images use the system document chooser, without broad storage access.
Future<bool> exportPageImage(
  File source, {
  required String suggestedName,
}) async {
  if (Platform.isAndroid) {
    return await const MethodChannel('dev.levalue.kmreader/export')
            .invokeMethod<bool>('exportImage', {
              'path': source.path,
              'name': suggestedName,
            }) ??
        false;
  }
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: [
      const XTypeGroup(label: 'PNG', extensions: ['png']),
    ],
  );
  if (location == null) return false;
  await source.copy(location.path);
  return true;
}

/// Re-encode decoded page formats as PNG and remove temporary files on every exit.
Future<bool> saveEncodedPageImage(
  Uint8List bytes,
  Directory directory, {
  required int page,
}) async {
  Directory? temporary;
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw const FormatException('Unable to encode the page.');
    temporary = await directory.createTemp('page-export-');
    final source = File('${temporary.path}/page.png');
    await source.writeAsBytes(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
    return await exportPageImage(
      source,
      suggestedName: 'kmreader-page-$page.png',
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    if (temporary != null) await temporary.delete(recursive: true);
  }
}
