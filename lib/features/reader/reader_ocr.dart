import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';

class OcrBlock {
  OcrBlock(this.text, this.bounds);
  final String text;

  /// Coordinates are normalized to the oriented source image.
  final Rect bounds;
}

class OcrDocument {
  OcrDocument(this.width, this.height, this.text, this.blocks);
  final double width, height;
  final String text;
  final List<OcrBlock> blocks;
  factory OcrDocument.parse(Json value) {
    final width = value['width'], height = value['height'];
    if (width is! num ||
        height is! num ||
        !width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0) {
      throw const FormatException('Invalid OCR image size.');
    }
    final blocks = <OcrBlock>[];
    for (final raw in value['blocks'] as List? ?? []) {
      final block = object(raw),
          x = block['x'],
          y = block['y'],
          w = block['width'],
          h = block['height'];
      if ([x, y, w, h].any((n) => n is! num || !n.isFinite) ||
          (w as num) <= 0 ||
          (h as num) <= 0) {
        continue;
      }
      final left = (x as num).toDouble().clamp(0, width.toDouble()),
          top = (y as num).toDouble().clamp(0, height.toDouble());
      final right = (x.toDouble() + w.toDouble()).clamp(left, width.toDouble()),
          bottom = (y.toDouble() + h.toDouble()).clamp(top, height.toDouble());
      final content = textValue(block['text']);
      if (content.isEmpty) continue;
      blocks.add(
        OcrBlock(
          content,
          Rect.fromLTRB(
            left / width,
            top / height,
            right / width,
            bottom / height,
          ),
        ),
      );
    }
    return OcrDocument(
      width.toDouble(),
      height.toDouble(),
      textValue(value['text']),
      blocks,
    );
  }
  static String textValue(dynamic value) => value is String ? value : '';
}

class ReaderOcr {
  ReaderOcr(
    this.directory, {
    this.channel = const MethodChannel('dev.levalue.kmreader/ocr'),
  });
  final Directory directory;
  final MethodChannel channel;
  Future<List<String>> languages() async {
    final result = object(await channel.invokeMethod<dynamic>('capabilities'));
    return (result['languages'] as List? ?? []).whereType<String>().toList();
  }

  Future<OcrDocument> recognize(
    Uint8List bytes,
    String language, {
    bool cache = true,
  }) async {
    if (bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('Choose an image smaller than 32 MiB.');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(language)) {
      throw const FormatException('Unsupported OCR language.');
    }
    final id = await compute(_ocrImageHash, bytes);
    final target = File('${directory.path}/ocr/$id-$language-v1.json');
    if (cache && await target.exists()) {
      try {
        return OcrDocument.parse(
          object(jsonDecode(await target.readAsString())),
        );
      } on FormatException {
        /* Rebuild invalid cache entries. */
      }
    }
    await target.parent.create(recursive: true);
    final source = File(
      '${target.parent.path}/$id-${DateTime.now().microsecondsSinceEpoch}.image',
    );
    try {
      await source.writeAsBytes(bytes, flush: true);
      final value = object(
        await channel.invokeMethod<dynamic>('recognize', {
          'path': source.absolute.path,
          'language': language,
        }),
      );
      final document = OcrDocument.parse(value);
      if (cache) {
        final temporary = File('${target.path}.part');
        await temporary.writeAsString(jsonEncode(value), flush: true);
        if (await target.exists()) await target.delete();
        await temporary.rename(target.path);
      }
      return document;
    } finally {
      if (await source.exists()) await source.delete();
    }
  }
}

String _ocrImageHash(Uint8List bytes) => sha256.convert(bytes).toString();
