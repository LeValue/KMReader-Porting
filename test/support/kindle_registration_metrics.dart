import 'dart:convert';

import 'package:xml/xml.dart';

/// Fixed vocabulary only. Never report arbitrary server strings or XML text.
Map<String, dynamic> kindleRegistrationMetrics(List<int> bytes) {
  final result = <String, dynamic>{'format': 'other'};
  const fields = {
    'adp_token',
    'device_private_key',
    'user_directed_id',
    'error',
    'errors',
    'code',
    'message',
    'error_code',
    'error_description',
    'response',
    'parameters',
    'exception',
    'reason',
  };
  try {
    final xml = XmlDocument.parse(utf8.decode(bytes));
    result['format'] = 'xml';
    result['root'] = fields.contains(xml.rootElement.name.local)
        ? xml.rootElement.name.local
        : 'other';
    final names = xml.descendants
        .whereType<XmlElement>()
        .map((e) => e.name.local)
        .toSet();
    result['fields'] = fields.where(names.contains).toList()..sort();
    result['other_fields'] = names.difference(fields).length;
  } catch (_) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      result['format'] = 'json';
      if (value is Map) {
        result['fields'] = fields.where(value.containsKey).toList()..sort();
      }
    } catch (_) {
      /* No raw body, even when the response isn't XML/JSON. */
    }
  }
  return result;
}
