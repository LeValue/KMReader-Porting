import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../../core/models.dart';
import '../../core/store.dart';

class CustomFontStore {
  CustomFontStore(this.store, this.directory);
  final LocalStore store;
  final Directory directory;
  List<Json> get fonts =>
      (store.setting<List<dynamic>>('customFonts') ?? []).map(object).toList();
  File file(Json font) =>
      File('${directory.path}/fonts/${font['id']}.${font['extension']}');
  Future<Json?> importFont() async {
    final chosen = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Fonts',
          extensions: ['ttf', 'otf', 'woff', 'woff2'],
        ),
      ],
    );
    if (chosen == null) return null;
    return importFile(chosen);
  }

  Future<Json> importFile(XFile chosen) async {
    if (await chosen.length() > 32 * 1024 * 1024) {
      throw const FormatException('Choose a font smaller than 32 MiB.');
    }
    final bytes = await chosen.readAsBytes();
    final format = fontFormat(bytes);
    if (format == null) throw const FormatException('Unsupported font file.');
    final id = await compute(_fontHash, bytes);
    final record = <String, dynamic>{
      'id': id,
      'name': chosen.name.replaceAll(
        RegExp(r'\.(ttf|otf|woff2?)$', caseSensitive: false),
        '',
      ),
      'extension': format,
    };
    final target = file(record);
    await target.parent.create(recursive: true);
    if (!await target.exists()) {
      final temporary = File('${target.path}.part');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    }
    store.setSetting('customFonts', [
      ...fonts.where((v) => v['id'] != id),
      record,
    ]);
    return record;
  }

  Future<void> remove(String id) async {
    final font = fonts.where((v) => v['id'] == id).firstOrNull;
    if (font == null) return;
    store.setSetting('customFonts', fonts.where((v) => v['id'] != id).toList());
    final target = file(font);
    if (await target.exists()) await target.delete();
  }

  static String? fontFormat(List<int> bytes) {
    if (bytes.length < 12) return null;
    final header = String.fromCharCodes(bytes.take(4));
    if (header == 'OTTO') return 'otf';
    if (header == 'wOFF') return 'woff';
    if (header == 'wOF2') return 'woff2';
    if (bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0) {
      return 'ttf';
    }
    return null;
  }
}

String _fontHash(Uint8List bytes) => sha256.convert(bytes).toString();
