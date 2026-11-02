import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final directory = Directory('artifacts/local-windows')
      ..createSync(recursive: true);
    await File('${directory.path}/epub-frame-times.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  },
  writeResponseOnFailure: true,
);
