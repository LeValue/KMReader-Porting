import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'support/kindle_registration_metrics.dart';

void main() {
  test(
    'live registration report never copies server values or unknown names',
    () {
      for (final body in [
        '<response><adp_token>PRIVATE</adp_token><device_private_key>PRIVATE</device_private_key><PRIVATE>PRIVATE</PRIVATE><error code="PRIVATE">PRIVATE</error></response>',
        '{"error":"PRIVATE","PRIVATE":"PRIVATE"}',
        '<html>PRIVATE',
      ]) {
        final result = jsonEncode(kindleRegistrationMetrics(utf8.encode(body)));
        expect(result, isNot(contains('PRIVATE')));
      }
      expect(
        kindleRegistrationMetrics(
          utf8.encode('<response><error>PRIVATE</error></response>'),
        ),
        {
          'format': 'xml',
          'root': 'response',
          'fields': ['error', 'response'],
          'other_fields': 0,
        },
      );
    },
  );
}
