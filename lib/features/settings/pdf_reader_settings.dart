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
      value.setting<bool>('useNativePdfReader') != false;
  @override
  Widget build(BuildContext context) => PreferencePage(
    title: 'PDF Reader',
    store: store,
    specs: [
      PreferenceSpec(
        'useNativePdfReader',
        'Use Native PDF Reader',
        true,
        captionValue: (value) => _native(value)
            ? 'Native PDF Reader uses the system PDF engine and works best for text-heavy PDF books.'
            : 'PDF books open with DIVINA Reader. Recommended for comic and manga PDFs, especially when offline-downloaded pages are rendered as images.',
      ),
      PreferenceSpec(
        'rtl',
        'Preferred Direction',
        'ltr',
        bucket: 'pdfDefault',
        section: 'Default Reading Options',
        visible: _native,
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
        visible: _native,
        invertBool: true,
        caption: 'Ignore book and series metadata and always use the preferred direction',
      ),
      PreferenceSpec(
        'presentation',
        'Page Presentation',
        'auto',
        bucket: 'pdfDefault',
        visible: _native,
        choices: const {
          'auto': 'Auto',
          'single-paged': 'Single Page',
          'single-continuous': 'Single Page Continuous',
          'dual-continuous': 'Dual Page Continuous',
        },
        choiceIcons: const {
          'auto': Icons.auto_awesome_outlined,
          'single-paged': Icons.crop_portrait,
          'single-continuous': Icons.view_day_outlined,
          'dual-continuous': Icons.splitscreen_outlined,
        },
        captionValue: (value) =>
            const {
              'single-paged':
                  'Uses the native page controller for discrete page turns.',
              'single-continuous':
                  'Scrolls through one page at a time continuously.',
              'dual-continuous':
                  'Scrolls through two-page spreads continuously.',
            }[_defaults(value)['presentation']] ??
            'Uses dual-page continuous mode in landscape and single-page paged mode in portrait.',
      ),
      PreferenceSpec(
        'coverSolo',
        'Solo Cover Page',
        true,
        bucket: 'pdfDefault',
        visible: (value) =>
            _native(value) &&
            const [
              'auto',
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
        visible: _native,
        choices: backgroundChoices,
        caption: 'The background color of the reader',
      ),
      PreferenceSpec(
        'controlsGradient',
        'Controls Gradient Background',
        true,
        bucket: 'pdfDefault',
        section: 'Reader Overlay',
        visible: _native,
        caption: 'Add a gradient behind reader controls for better contrast over pages.',
      ),
      PreferenceSpec(
        'showProgress',
        'Show Progress Bar While Reading',
        false,
        bucket: 'pdfDefault',
        visible: _native,
        caption: 'Keep book progress pinned to the bottom until reader controls are shown.',
      ),
      PreferenceSpec(
        'pdfOfflineRenderQuality',
        'Render Quality',
        'balanced',
        section: 'Offline DIVINA Rendering',
        visible: (value) => !_native(value),
        choices: {
          for (final quality in PdfRasterQuality.values)
            quality.name: quality.label,
        },
        caption:
            'Used for offline-downloaded PDF books rendered by DIVINA Reader.',
      ),
    ],
  );
}
