import '../models.dart';

/// Catalog flags are authoritative; names also identify legacy cached dictionaries.
bool isKindleDictionary(Json item) {
  bool yes(dynamic value) =>
      value == true ||
      const {'1', 'true', 'yes'}.contains('$value'.toLowerCase());
  if ([
    'is_dictionary',
    'isDictionary',
    'is_amazon_dictionary',
  ].any((key) => yes(item[key]))) {
    return true;
  }
  final tags = [
    item['content_tags'],
    item['tags'],
    item['classification'],
    item['cde_contenttype'],
    item['type'],
  ].expand((v) => '$v'.toUpperCase().split(RegExp(r'[^A-Z_]+'))).toSet();
  if (tags.intersection({
    'DICT',
    'FREE_DICT',
    'DICTIONARY',
    'DICTIONARIES',
  }).isNotEmpty) {
    return true;
  }
  final title = text(item['title'])
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (const {
    'dictionary',
    'dizionario',
    'woordenboek',
    'wörterbuch',
    'dictionnaire',
    'diccionario',
    'dicionário',
  }.contains(title)) {
    return true;
  }
  final reference = RegExp(
    r'\b(dictionary|dictionaries|dizionario|dizionari|woordenboek|woordenboeken|wörterbuch|wörterbücher|dictionnaire|diccionario|dicionário)\b',
    unicode: true,
  );
  final publisher = RegExp(
    r'\b(oxford|collins|merriam.?webster|duden|larousse|pons|langenscheidt|van dale|priberam)\b',
  );
  if (reference.hasMatch(title) && publisher.hasMatch(title)) return true;
  return RegExp(
    r'^(?:het |the |le |il )?(?:groot|grote|klein|kleine) woordenboek\b',
  ).hasMatch(title);
}
