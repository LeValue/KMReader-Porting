import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  bool _closed = false;
  final _active = <Future<OcrDocument>>{};
  Future<void> get settled => Future.wait(
    _active.map((work) => work.then<void>((_) {}, onError: (Object _) {})),
  );
  void close() {
    _closed = true;
  }

  Future<List<String>> languages() async {
    if (_closed) throw const FormatException('Text recognition was closed.');
    final result = object(await channel.invokeMethod<dynamic>('capabilities'));
    return (result['languages'] as List? ?? []).whereType<String>().toList();
  }

  Future<OcrDocument> recognize(
    Uint8List bytes,
    String language, {
    bool cache = true,
  }) {
    if (_closed) {
      return Future.error(
        const FormatException('Text recognition was closed.'),
      );
    }
    final work = _recognize(bytes, language, cache: cache);
    _active.add(work);
    return work.whenComplete(() => _active.remove(work));
  }

  Future<OcrDocument> _recognize(
    Uint8List bytes,
    String language, {
    required bool cache,
  }) async {
    if (bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('Choose an image smaller than 32 MiB.');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(language)) {
      throw const FormatException('Unsupported OCR language.');
    }
    final id = await compute(_ocrImageHash, bytes);
    if (_closed) throw const FormatException('Text recognition was closed.');
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
    final operation =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final source = File('${target.parent.path}/$id-$operation.image');
    try {
      if (_closed) throw const FormatException('Text recognition was closed.');
      await source.writeAsBytes(bytes, flush: true);
      if (_closed) throw const FormatException('Text recognition was closed.');
      final value = object(
        await channel
            .invokeMethod<dynamic>('recognize', {
              'path': source.absolute.path,
              'language': language,
            })
            .timeout(const Duration(seconds: 45)),
      );
      final document = OcrDocument.parse(value);
      if (cache && !_closed) {
        final temporary = File('${target.path}.$operation.part');
        try {
          await temporary.writeAsString(jsonEncode(value), flush: true);
          await temporary.rename(target.path);
        } on FileSystemException {
          // Cache failure must not discard successfully recognized text.
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      return document;
    } finally {
      if (await source.exists()) await source.delete();
    }
  }
}

String _ocrImageHash(Uint8List bytes) => sha256.convert(bytes).toString();
