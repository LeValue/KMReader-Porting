import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class Strings {
  Strings(this.locale);
  final Locale locale;
  static Map<String, dynamic> _catalog = {};
  static final Map<String, Map<dynamic, dynamic>> _english = {};
  static Future<void> initialize() async {
    _catalog = jsonDecode(await rootBundle.loadString('assets/strings.json'));
    final port = jsonDecode(
      await rootBundle.loadString('assets/port_strings.json'),
    ) as Map<String, dynamic>;
    for (final entry in port.entries) {
      _catalog[entry.key] = {
        if (_catalog[entry.key] case final Map upstream) ...upstream,
        ...entry.value as Map,
      };
    }
    _english.clear();
    for (final entry in _catalog.entries) {
      final value = entry.value as Map;
      final english = value['en'] as String? ?? entry.key;
      final alias = _english.putIfAbsent(english.toLowerCase(), () => {});
      for (final translation in value.entries) {
        alias.putIfAbsent(translation.key, () => translation.value);
      }
    }
  }

  static const locales = [
    Locale('en'),
    Locale('it'),
    Locale('de'),
    Locale('fr'),
    Locale('ja'),
    Locale('ko'),
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
      countryCode: 'CN',
    ),
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
    Locale('ru'),
    Locale('es'),
  ];
  static Locale? preferredLocale(String? setting) {
    if (setting == null) return null;
    final parts = setting.replaceAll('-', '_').split('_');
    final language = parts.first.toLowerCase();
    return locales
        .where(
          (supported) =>
              supported.languageCode == language &&
              (language != 'zh' ||
                  supported.scriptCode ==
                      (parts.any(
                            (part) => const {
                              'hant',
                              'tw',
                              'hk',
                              'mo',
                            }.contains(part.toLowerCase()),
                          )
                          ? 'Hant'
                          : 'Hans')),
        )
        .firstOrNull;
  }

  String call(String key, [Map<String, Object> arguments = const {}]) {
    final lang = locale.languageCode == 'zh'
        ? locale.scriptCode == 'Hant' ||
                  locale.scriptCode == null &&
                      const {'TW', 'HK', 'MO'}.contains(locale.countryCode)
              ? 'zh-Hant'
              : 'zh-Hans'
        : locale.languageCode;
    final entries = _catalog[key] as Map?;
    final english = entries?['en'] as String? ?? key;
    final alias = _english[english.toLowerCase()];
    final translation =
        entries?[lang] as String? ??
        alias?[lang] as String? ??
        alias?['en'] as String? ??
        english;
    return arguments.isEmpty
        ? translation
        : translation.replaceAllMapped(
            RegExp(r'\{(\w+)\}'),
            (match) => arguments[match[1]]?.toString() ?? match[0]!,
          );
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

String tr(
  BuildContext context,
  String key, [
  Map<String, Object> arguments = const {},
]) => Strings.of(context)(key, arguments);
