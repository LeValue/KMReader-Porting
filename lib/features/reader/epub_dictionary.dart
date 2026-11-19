import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

String? dictionaryWord(String selection) {
  final word = selection.trim().toLowerCase();
  return word.length <= 80 &&
          RegExp(
            r"^[\p{L}\p{M}]+(?:[-'’][\p{L}\p{M}]+)*$",
            unicode: true,
          ).hasMatch(word)
      ? word
      : null;
}

String dictionaryLanguage(String language) {
  final base = language.toLowerCase().split(RegExp('[-_]')).first;
  return const {'it', 'en', 'de', 'es', 'fr', 'pt'}.contains(base)
      ? base
      : 'en';
}

Future<List<String>> lookupDictionary(String word, String language) async {
  final client = http.Client();
  try {
    final uri = Uri.https(
      '${dictionaryLanguage(language)}.wiktionary.org',
      '/w/api.php',
      {
        'action': 'parse',
        'page': word,
        'prop': 'text',
        'format': 'json',
        'formatversion': '2',
        'redirects': '1',
      },
    );
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['User-Agent'] =
          'KMReader/1.0 (https://github.com/LeValue/KMReader-Porting)';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return [];
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 8),
    )) {
      if (bytes.length + chunk.length > 512 * 1024) return [];
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    final body = data is Map && data['parse'] is Map
        ? data['parse']['text']
        : null;
    if (body is! String) return [];
    return dictionaryDefinitions(body);
  } finally {
    client.close();
  }
}

List<String> dictionaryDefinitions(String htmlText) {
  final document = html.parse(htmlText);
  final results = <String>{};
  for (final item in document.querySelectorAll('ol > li')) {
    for (final nested in item.querySelectorAll('ul, ol, dl, sup, .reference')) {
      nested.remove();
    }
    final definition = item.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (definition.isEmpty) continue;
    results.add(String.fromCharCodes(definition.runes.take(500)));
    if (results.length == 6) break;
  }
  return results.toList();
}
