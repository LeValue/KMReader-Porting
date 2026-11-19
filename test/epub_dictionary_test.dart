import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/features/reader/epub_dictionary.dart';

void main() {
  test('dictionary accepts one word and normalizes EPUB language tags', () {
    expect(dictionaryWord(' ÉLÈVE '), 'élève');
    expect(dictionaryWord('L’AMICA'), 'l’amica');
    expect(dictionaryWord('Una frase privata'), isNull);
    expect(dictionaryWord('42'), isNull);
    expect(dictionaryLanguage('it-IT'), 'it');
    expect(dictionaryLanguage('pt_BR'), 'pt');
    expect(dictionaryLanguage('unknown'), 'en');
  });

  test('definitions retain plain text without examples or references', () {
    expect(
      dictionaryDefinitions(
        '<ol><li>Prima <em>definizione</em><sup>1</sup>'
        '<ul><li>Esempio</li></ul></li><li>Seconda definizione</li></ol>',
      ),
      ['Prima definizione', 'Seconda definizione'],
    );
  });
}
