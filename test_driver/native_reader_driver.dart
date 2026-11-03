import 'dart:io';
import 'dart:convert';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    if (data == null) return;
    final directory = Directory('artifacts/android-epub-recovery')
      ..createSync(recursive: true);
    for (final entry in data['epubRecoveryScreenshots'] as List? ?? const []) {
      final snapshot = Map<String, dynamic>.from(entry as Map);
      final name = snapshot['phase'].toString().replaceAll(
        RegExp(r'[^a-zA-Z0-9_-]'),
        '_',
      );
      await File('${directory.path}/$name.png')
          .writeAsBytes(base64Decode(snapshot['png'] as String));
    }
    final summary = Map<String, dynamic>.from(data)
      ..remove('epubRecoveryScreenshots');
    await File('${directory.path}/report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(summary));
  },
  onScreenshot: (name, bytes, [args]) async {
    final directory = Directory('artifacts/native-epub')
      ..createSync(recursive: true);
    await File('${directory.path}/$name.png').writeAsBytes(bytes);
    return true;
  },
);
