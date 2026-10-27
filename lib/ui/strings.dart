import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class Strings {
  Strings(this.locale);
  final Locale locale;
  static Map<String, dynamic> _catalog = {};
  static final Map<String, dynamic> _english = {};
  static Future<void> initialize() async {
    _catalog = jsonDecode(await rootBundle.loadString('assets/strings.json'));
    for (final entry in _catalog.entries) {
      final value = entry.value as Map;
      final english = value['en'] as String? ?? entry.key;
      _english.putIfAbsent(english.toLowerCase(), () => value);
    }
  }

  static const locales = [
    Locale('en'),
    Locale('it'),
    Locale('de'),
    Locale('fr'),
    Locale('ja'),
    Locale('ko'),
    Locale('zh', 'CN'),
    Locale('zh', 'TW'),
    Locale('ru'),
    Locale('es'),
  ];
  String call(String key) {
    final lang = locale.languageCode == 'zh'
        ? (locale.countryCode == 'TW' ? 'zh-Hant' : 'zh-Hans')
        : locale.languageCode;
    final entries = _catalog[key] ?? _english[key.toLowerCase()];
    if (entries is Map) {
      return entries[lang] as String? ?? entries['en'] as String? ?? key;
    }
    return key;
  }

  static Strings of(BuildContext context) =>
      Localizations.of<Strings>(context, Strings) ??
      Strings(const Locale('en'));
  static const delegate = _StringsDelegate();
}

class _StringsDelegate extends LocalizationsDelegate<Strings> {
  const _StringsDelegate();
  @override
  bool isSupported(Locale locale) =>
      Strings.locales.any((v) => v.languageCode == locale.languageCode);
  @override
  Future<Strings> load(Locale locale) => SynchronousFuture(Strings(locale));
  @override
  bool shouldReload(_StringsDelegate old) => false;
}

String tr(BuildContext context, String key) => Strings.of(context)(key);
