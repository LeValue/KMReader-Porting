import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/reader_defaults.dart';
import '../../core/store.dart';
import '../reader/pdf_raster_pages.dart';
import 'preference_controls.dart';
import 'reader_settings.dart' show backgroundChoices;

class PdfReaderSettingsPage extends StatelessWidget {
  const PdfReaderSettingsPage({super.key, required this.store});
  final LocalStore store;
  Json _defaults(LocalStore value) =>
      object(value.setting<dynamic>('pdfDefault'));
  bool _native(LocalStore value) =>
      value.setting<bool>('useNativePdfReader') == true;
  @override
  Widget build(BuildContext context) => PreferencePage(
    title: 'PDF Reader',
    store: store,
    specs: [
      PreferenceSpec(
        'useNativePdfReader',
        'Use Native PDF Reader',
        false,
        captionValue: (value) =>
            _native(value) ? 'The native PDF view supports selectable text.' : 'PDFs open in the comics reader with search and a table of contents.',
      ),
      PreferenceSpec(
        'pdfOfflineRenderQuality',
        'Render Quality',
        'balanced',
        section: 'PDF Page Rendering',
        visible: (value) => !_native(value),
        choices: {
          for (final quality in PdfRasterQuality.values)
            quality.name: quality.label,
        },
        caption: 'Image quality for PDF pages in the comics reader.',
      ),
      PreferenceSpec(
        'rtl',
        'Preferred Direction',
        'ltr',
        bucket: 'pdfDefault',
        section: 'Default Reading Options',
        choices: const {
          'ltr': 'Left to Right',
          'rtl': 'Right to Left',
          'vertical': 'Vertical',
        },
        readValue: (value) => _defaults(value)['vertical'] == true
            ? 'vertical'
            : _defaults(value)['rtl'] == true
            ? 'rtl'
            : 'ltr',
        writeValue: (value, direction) => updateReaderDefaults(
          value,
          'pdfDefault',
          {'rtl': direction == 'rtl', 'vertical': direction == 'vertical'},
        ),
        caption:
            "Used when a book or series doesn't specify a reading direction",
      ),
      PreferenceSpec(
        'useSeriesDirection',
        'Force Default Reading Direction',
        true,
        bucket: 'pdfDefault',
        invertBool: true,
        caption: 'Ignore book and series metadata and always use the preferred direction',
      ),
      PreferenceSpec(
        'presentation',
        'Page Presentation',
        'auto',
        bucket: 'pdfDefault',
        choices: const {
          'auto': 'Auto',
          'single-paged': 'Single Page',
          'dual-paged': 'Dual Page',
          'single-continuous': 'Single Page Continuous',
          'dual-continuous': 'Dual Page Continuous',
        },
        choiceIcons: const {
          'auto': Icons.auto_awesome_outlined,
          'single-paged': Icons.crop_portrait,
          'dual-paged': Icons.chrome_reader_mode_outlined,
          'single-continuous': Icons.view_day_outlined,
          'dual-continuous': Icons.splitscreen_outlined,
        },
        captionValue: (value) =>
            const {
              'single-paged': 'Turns one page at a time.',
              'dual-paged': 'Turns two-page spreads one at a time.',
              'single-continuous':
                  'Scrolls through one page at a time continuously.',
              'dual-continuous':
                  'Scrolls through two-page spreads continuously.',
            }[_defaults(value)['presentation']] ??
            'Uses two pages in landscape and one page in portrait.',
      ),
      PreferenceSpec(
        'coverSolo',
        'Solo Cover Page',
        true,
        bucket: 'pdfDefault',
        visible: (value) => const [
          'auto',
          'dual-paged',
          'dual-continuous',
        ].contains(_defaults(value)['presentation'] ?? 'auto'),
        caption: 'Show the first page alone before entering dual-page spread',
      ),
      PreferenceSpec(
        'background',
        'Reader Background',
        'white',
        bucket: 'pdfDefault',
        section: 'Appearance',
        choices: backgroundChoices,
        caption: 'The background color of the reader',
      ),
      PreferenceSpec(
        'controlsGradient',
        'Controls Gradient Background',
        true,
        bucket: 'pdfDefault',
        section: 'Reader Overlay',
        caption: 'Add a gradient behind reader controls for better contrast over pages.',
      ),
      PreferenceSpec(
        'showProgress',
        'Show Progress Bar While Reading',
        false,
        bucket: 'pdfDefault',
        caption: 'Keep book progress pinned to the bottom until reader controls are shown.',
      ),
    ],
  );
}
