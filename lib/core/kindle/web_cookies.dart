import 'dart:io';

import '../models.dart';

/// A short-lived, account-owned jar for Amazon.it. Cookie identity includes
/// domain and path: clearing a www-only cookie must not clear its parent-domain
/// counterpart minted by the refresh-token exchange.
class KindleWebsiteCookies {
  final _values = <(String, String, String), (String, int)>{};
  var _sequence = 0;
  static bool _domain(String value) =>
      const {'amazon.it', 'www.amazon.it'}.contains(value);
  static bool _name(String value) =>
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
  static bool _value(String value) =>
      !RegExp(r'[;\x00-\x20\x7f]').hasMatch(value);
  static String _canonical(String value) =>
      value.toLowerCase().replaceFirst(RegExp(r'^\.'), '');

  void exchange(dynamic raw) {
    for (final entry in object(raw).entries) {
      final domain = _canonical(entry.key);
      if (!_domain(domain)) continue;
      for (final item in (entry.value as List? ?? []).map(object)) {
        final name = text(item['Name']);
        final value = text(item['Value']).replaceAll('"', '');
        var path = text(item['Path']);
        if (path.isEmpty) path = '/';
        if (_name(name) && _value(value) && path.startsWith('/')) {
          _put((domain, path, name), value);
        }
      }
    }
  }

  void _put((String, String, String) key, String value) =>
      _values[key] = (value, _values[key]?.$2 ?? _sequence++);

  void receive(Uri origin, Map<String, String> headers, {DateTime? now}) {
    if (origin.scheme != 'https' || origin.host != 'www.amazon.it') return;
    final stamp = now ?? DateTime.now();
    for (final part in (headers['set-cookie'] ?? '').split(
      RegExp(r',(?=\s*[A-Za-z0-9_-]+=)'),
    )) {
      if (part.trim().isEmpty) continue;
      try {
        final cookie = Cookie.fromSetCookieValue(part.trim());
        final domain = cookie.domain == null
            ? origin.host
            : _canonical(cookie.domain!);
        final slash = origin.path.lastIndexOf('/');
        final path =
            cookie.path ?? (slash <= 0 ? '/' : origin.path.substring(0, slash));
        final value = cookie.value.replaceAll('"', '');
        if (!_domain(domain) ||
            !_name(cookie.name) ||
            !_value(value) ||
            !path.startsWith('/')) {
          continue;
        }
        final key = (domain, path, cookie.name);
        // Max-Age takes precedence over Expires (RFC 6265).
        final expired = cookie.maxAge != null
            ? cookie.maxAge! <= 0
            : cookie.expires?.isBefore(stamp) == true;
        if (expired) {
          _values.remove(key);
        } else {
          _put(key, value);
        }
      } on HttpException {
        /* Discard malformed Set-Cookie fields. */
      } on FormatException {
        /* Discard malformed Set-Cookie fields. */
      }
    }
  }

  String header(Uri target) {
    if (target.scheme != 'https' ||
        target.host != 'www.amazon.it' ||
        target.port != 443 ||
        target.userInfo.isNotEmpty) {
      return '';
    }
    final selected =
        _values.entries.where((entry) {
          final (domain, path, _) = entry.key;
          return (target.host == domain || target.host.endsWith('.$domain')) &&
              target.path.startsWith(path) &&
              (path.endsWith('/') ||
                  target.path.length == path.length ||
                  target.path[path.length] == '/');
        }).toList()..sort((a, b) {
          final length = b.key.$2.length.compareTo(a.key.$2.length);
          return length == 0 ? a.value.$2.compareTo(b.value.$2) : length;
        });
    return selected.map((e) => '${e.key.$3}=${e.value.$1}').join('; ');
  }
}
