import 'package:flutter/material.dart';

import '../../core/store.dart';
import '../../ui/strings.dart';
import '../reader/pdf_raster_pages.dart';
import 'preference_controls.dart';
import 'reader_settings.dart' show backgroundChoices;

class PdfReaderSettingsPage extends StatefulWidget {
  const PdfReaderSettingsPage({super.key, required this.store});
  final LocalStore store;
  @override
  State<PdfReaderSettingsPage> createState() => _PdfReaderSettingsPageState();
}

class _PdfReaderSettingsPageState extends State<PdfReaderSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final native = widget.store.setting<bool>('useNativePdfReader') != false;
    final quality = PdfRasterQuality.parse(
      widget.store.setting<String>('pdfOfflineRenderQuality'),
    );
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'PDF Reader'))),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(tr(context, 'Use Native PDF Reader')),
            subtitle: Text(
              tr(
                context,
                native
                    ? 'Native PDF Reader uses the system PDF engine and works best for text-heavy PDF books.'
                    : 'PDF books open with DIVINA Reader. Recommended for comic and manga PDFs, especially when offline-downloaded pages are rendered as images.',
              ),
            ),
            value: native,
            onChanged: (value) => setState(
              () => widget.store.setSetting('useNativePdfReader', value),
            ),
          ),
          if (!native) ...[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr(context, 'Render Quality'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final option in PdfRasterQuality.values)
              ListTile(
                title: Text(tr(context, option.label)),
                leading: Icon(
                  quality == option
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                selected: quality == option,
                onTap: () => setState(
                  () => widget.store.setSetting(
                    'pdfOfflineRenderQuality',
                    option.name,
                  ),
                ),
              ),
          ],
          PreferencePage(
            title: 'PDF Reader',
            store: widget.store,
            embedded: true,
            specs: const [
              PreferenceSpec(
                'rtl',
                'Right to Left',
                false,
                bucket: 'pdfDefault',
                section: 'Default Reading Options',
              ),
              PreferenceSpec(
                'useSeriesDirection',
                'Use Series Reading Direction',
                true,
                bucket: 'pdfDefault',
              ),
              PreferenceSpec(
                'presentation',
                'Page Presentation',
                'auto',
                bucket: 'pdfDefault',
                choices: {
                  'auto': 'Automatic',
                  'single-paged': 'Single Page',
                  'single-continuous': 'Single Page Continuous',
                  'dual-continuous': 'Dual Page Continuous',
                },
              ),
              PreferenceSpec(
                'coverSolo',
                'Solo Cover Page',
                true,
                bucket: 'pdfDefault',
              ),
              PreferenceSpec(
                'background',
                'Reader Background',
                'white',
                bucket: 'pdfDefault',
                section: 'Appearance',
                choices: backgroundChoices,
              ),
              PreferenceSpec(
                'controlsGradient',
                'Controls Gradient Background',
                true,
                bucket: 'pdfDefault',
              ),
              PreferenceSpec(
                'showProgress',
                'Show Progress Bar While Reading',
                false,
                bucket: 'pdfDefault',
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(tr(context, 'Changes apply when opening a PDF book.')),
          ),
        ],
      ),
    );
  }
}
