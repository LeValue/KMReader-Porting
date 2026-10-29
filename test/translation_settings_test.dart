import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/store.dart';
import 'package:kmreader/core/translation.dart';
import 'package:kmreader/features/settings/translation_settings.dart';
import 'package:kmreader/features/reader/reader_text_page.dart';
import 'package:sqlite3/sqlite3.dart';

import 'translation_test.dart' show Vault;

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('provider editing and selected text fit ${size.width}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = LocalStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final providers = TranslationProviders(store, vault: Vault());
      await tester.pumpWidget(
        MaterialApp(home: TranslationSettingsPage(providers: providers)),
      );
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'fixture-secret',
      );
      await tester.enterText(find.byType(TextFormField).at(3), 'test-model');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(providers.values.single.model, 'test-model');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderTextPage(
            initialText: 'Selected ebook text',
            providers: providers,
            title: 'Book',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Selected ebook text'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    });
  }
}
