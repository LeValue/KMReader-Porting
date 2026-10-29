import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../core/store.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../reader/custom_fonts.dart';
import 'preference_controls.dart';

const tapChoices = <Object, String>{
  'none': 'reader.tapZoneMode.none',
  'default': 'reader.tapZoneMode.default',
  'edge': 'reader.tapZoneMode.edge',
  'kindle': 'reader.tapZoneMode.kindle',
  'lShape': 'reader.tapZoneMode.lShape',
  'tSplit': 'reader.tapZoneMode.tSplit',
};
const inversionChoices = <Object, String>{
  'auto': 'reader.tapZoneInversionMode.auto',
  'normal': 'reader.tapZoneInversionMode.normal',
  'inverted': 'reader.tapZoneInversionMode.inverted',
};
const backgroundChoices = <Object, String>{
  'system': 'System',
  'black': 'Black',
  'white': 'White',
  'gray': 'Gray',
  'sepia': 'Sepia',
};
bool _epubAdvanced(LocalStore store) =>
    object(store.setting<dynamic>('epubDefault'))['advancedLayout'] != false;
bool _epubPaged(LocalStore store) =>
    object(store.setting<dynamic>('epubDefault'))['flow'] != 'scrolled';
bool _comicWebtoon(LocalStore store) =>
    object(store.setting<dynamic>('readerDefault'))['mode'] == 'webtoon';

const transitionChoices = <Object, String>{
  'slide': 'reader.page_transition.scroll',
  'cover': 'reader.page_transition.cover',
  'curl': 'reader.page_transition.page_curl',
};

class DivinaSettingsPage extends StatelessWidget {
  const DivinaSettingsPage({super.key, required this.repository});
  final Repository repository;
  void _changed(String key) {
    final settings = object(repository.store.setting<dynamic>('readerDefault'));
    if (key == 'pageLayout' && settings[key] == 'dual-forced') {
      repository.store.setSetting('readerDefault', {
        ...settings,
        'spread': true,
        'splitWide': 'none',
      });
    } else if (key == 'splitWide' && settings[key] != 'none') {
      repository.store.setSetting('readerDefault', {
        ...settings,
        'spread': false,
        'pageLayout': 'single',
      });
    }
  }

  @override
  Widget build(BuildContext context) => PreferencePage(
    title: 'DIVINA Reader',
    store: repository.store,
    onChanged: _changed,
    specs: [
      const PreferenceSpec(
        'mode',
        'Preferred Direction',
        'paged',
        bucket: 'readerDefault',
        section: 'Default Reading Options',
        choices: {
          'paged': 'Paged',
          'vertical': 'Vertical',
          'webtoon': 'Webtoon',
        },
      ),
      const PreferenceSpec(
        'direction',
        'Right to Left',
        'ltr',
        bucket: 'readerDefault',
        choices: {'ltr': 'Left to Right', 'rtl': 'Right to Left'},
      ),
      const PreferenceSpec(
        'useSeriesDirection',
        'Use Series Reading Direction',
        true,
        bucket: 'readerDefault',
      ),
      const PreferenceSpec(
        'pageLayout',
        'Page Layout',
        'single',
        bucket: 'readerDefault',
        choices: {
          'single': 'Single Page',
          'auto': 'Automatic',
          'dual-forced': 'Double Page',
        },
      ),
      const PreferenceSpec(
        'splitWide',
        'Split Wide Pages',
        'none',
        bucket: 'readerDefault',
        choices: {
          'none': 'Disabled',
          'auto': 'Automatic',
          'ltr': 'Left to Right',
          'rtl': 'Right to Left',
          'scroll': 'reader.splitWidePage.scroll',
        },
      ),
      const PreferenceSpec(
        'soloCover',
        'Solo Cover Page',
        false,
        bucket: 'readerDefault',
      ),
      const PreferenceSpec(
        'background',
        'Reader Background',
        'black',
        bucket: 'readerDefault',
        section: 'Appearance',
        choices: backgroundChoices,
      ),
      const PreferenceSpec(
        'showPageNumber',
        'Show Page Number',
        true,
        bucket: 'readerDefault',
      ),
      const PreferenceSpec(
        'showPageShadow',
        'Show Page Shadow',
        false,
        bucket: 'readerDefault',
      ),
      const PreferenceSpec(
        'controlsGradient',
        'Controls Gradient Background',
        true,
        bucket: 'readerDefault',
      ),
      const PreferenceSpec(
        'showProgress',
        'Show Progress Bar While Reading',
        false,
        bucket: 'readerDefault',
      ),
      PreferenceSpec(
        'webtoonWidth',
        'Webtoon Page Width',
        100.0,
        bucket: 'readerDefault',
        min: 50,
        max: 100,
        step: 5,
        visible: _comicWebtoon,
      ),
      const PreferenceSpec(
        'transition',
        'Page Transition Style',
        'cover',
        bucket: 'readerDefault',
        section: 'Page Turn',
        choices: transitionChoices,
      ),
      const PreferenceSpec(
        'animate',
        'Animate Page Turns',
        true,
        bucket: 'readerDefault',
      ),
      const PreferenceSpec(
        'tapMode',
        'Tap Zones',
        'default',
        bucket: 'readerDefault',
        choices: tapChoices,
      ),
      const PreferenceSpec(
        'tapInversion',
        'Tap Zone Mirroring',
        'auto',
        bucket: 'readerDefault',
        choices: inversionChoices,
      ),
      const PreferenceSpec(
        'showTapHints',
        'Show Tap Zone Hints',
        false,
        bucket: 'readerDefault',
      ),
      PreferenceSpec(
        'tapScroll',
        'Webtoon Tap Scroll Height',
        80.0,
        bucket: 'readerDefault',
        min: 25,
        max: 100,
        step: 5,
        visible: _comicWebtoon,
      ),
      const PreferenceSpec(
        'doubleTapEnabled',
        'Double Tap Zoom',
        true,
        bucket: 'readerDefault',
        section: 'Zooming',
      ),
      PreferenceSpec(
        'doubleTapZoom',
        'Double Tap Zoom Scale',
        2.0,
        bucket: 'readerDefault',
        min: 1,
        max: 8,
        step: .5,
        enabled: (store) =>
            object(
              store.setting<dynamic>('readerDefault'),
            )['doubleTapEnabled'] !=
            false,
      ),
      const PreferenceSpec(
        'preload',
        'Image Preloading',
        'balanced',
        bucket: 'readerDefault',
        section: 'Images',
        choices: {
          'lowMemory': 'Low Memory',
          'balanced': 'Balanced',
          'fastPageTurns': 'Fast Page Turns',
        },
      ),
      const PreferenceSpec(
        'borderCrop',
        'Border Cropping',
        'disabled',
        bucket: 'readerDefault',
        choices: {
          'disabled': 'Disabled',
          'conservative': 'Conservative',
          'aggressive': 'Aggressive',
        },
      ),
      const PreferenceSpec(
        'imageUpscalingMode',
        'Waifu2x Mode',
        'disabled',
        choices: {'disabled': 'Disabled', 'auto': 'Automatic'},
      ),
      PreferenceSpec(
        'imageUpscaleAutoTriggerScale',
        'Upscale Trigger Scale',
        1.05,
        min: 1,
        max: 3,
        step: .05,
        visible: (store) =>
            store.setting<String>('imageUpscalingMode') == 'auto',
      ),
      const PreferenceSpec(
        'liveText',
        'Live Text',
        false,
        bucket: 'readerDefault',
      ),
      const PreferenceSpec(
        'imageContextMenu',
        'Image Context Menu',
        true,
        bucket: 'readerDefault',
      ),
    ],
  );
}

class ReaderGeneralSettingsPage extends StatelessWidget {
  const ReaderGeneralSettingsPage({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => PreferencePage(
    title: 'Reader General',
    footer: ListenableBuilder(
      listenable: repository,
      builder: (context, _) => SwitchListTile(
        title: Text(tr(context, 'Read List Continuation')),
        value: repository.readLists.enabled,
        onChanged: repository.readLists.setEnabled,
      ),
    ),
    store: repository.store,
    onChanged: (_) => repository.changed(),
    specs: const [
      PreferenceSpec(
        'offlineFirstReading',
        'Offline-first Reading',
        false,
        section: 'Offline Reading',
        caption:
            'Download books before opening them, then read from local storage.',
      ),
      PreferenceSpec(
        'offlineAutoDeleteRead',
        'settings.offline.auto_delete_read',
        false,
        caption: 'settings.offline.auto_delete_read.message',
        confirmEnable: true,
      ),
      PreferenceSpec(
        'progressRecordingThreshold',
        'Record Progress After',
        0,
        section: 'Reading Progress',
        choices: {
          0: 'Immediately',
          1: '1 page',
          3: '3 pages',
          5: '5 pages',
          10: '10 pages',
        },
      ),
      PreferenceSpec(
        'suggestNextUnreadBook',
        'settings.reader.suggestNextUnreadBook.title',
        true,
        section: 'Next Book',
      ),
      PreferenceSpec(
        'showKeyboardHelpOverlay',
        'Auto-Show Keyboard Help',
        true,
        section: 'Keyboard',
      ),
      PreferenceSpec(
        'spaceKeyAction',
        'reader.spaceKeyAction.title',
        'toggleControls',
        choices: {
          'toggleControls': 'reader.spaceKeyAction.toggleControls',
          'nextPage': 'reader.spaceKeyAction.nextPage',
        },
      ),
      PreferenceSpec(
        'autoFullscreenOnOpen',
        'Auto Full Screen on Open',
        false,
        section: 'Screen',
      ),
      PreferenceSpec(
        'keepScreenAwakeWhileReading',
        'Keep Screen Awake While Reading',
        false,
      ),
    ],
  );
}

class EpubSettingsPage extends StatelessWidget {
  const EpubSettingsPage({super.key, required this.store});
  final LocalStore store;
  @override
  Widget build(BuildContext context) => PreferencePage(
    title: 'EPUB Settings',
    store: store,
    specs: [
      const PreferenceSpec(
        'epubRenderingEngine',
        'Rendering Engine',
        'webView',
        choices: {'webView': 'WebView', 'native': 'Native'},
      ),
      const PreferenceSpec(
        'flow',
        'epub.reading_flow',
        'paged',
        bucket: 'epubDefault',
        section: 'Page Turn',
        choices: {'paged': 'Paged', 'scrolled': 'Continuous'},
      ),
      PreferenceSpec(
        'animate',
        'Animate Page Turns',
        true,
        bucket: 'epubDefault',
        visible: _epubPaged,
      ),
      PreferenceSpec(
        'transition',
        'Page Transition Style',
        'slide',
        bucket: 'epubDefault',
        choices: transitionChoices,
        visible: _epubPaged,
      ),
      PreferenceSpec(
        'tapScroll',
        'epub.scrolled.tap_scroll_height',
        80.0,
        bucket: 'epubDefault',
        min: 25,
        max: 100,
        step: 5,
        visible: (store) => !_epubPaged(store),
      ),
      const PreferenceSpec(
        'tapMode',
        'Tap Zones',
        'default',
        bucket: 'epubDefault',
        section: 'Tap Zones',
        choices: tapChoices,
      ),
      const PreferenceSpec(
        'tapInversion',
        'Tap Zone Mirroring',
        'auto',
        bucket: 'epubDefault',
        choices: inversionChoices,
      ),
      const PreferenceSpec(
        'epubShowsStatusBarWhileReading',
        'Show Status Bar While Reading',
        false,
        section: 'Reader Overlay',
      ),
      for (final entry in const {
        'readerHeaderLeading': 'epub.overlay.header_left',
        'readerHeaderCenter': 'epub.overlay.header_center',
        'readerHeaderTrailing': 'epub.overlay.header_right',
        'readerFooterLeading': 'epub.overlay.footer_left',
        'readerFooterCenter': 'epub.overlay.footer_center',
        'readerFooterTrailing': 'epub.overlay.footer_right',
        'controlsHeaderCenter': 'epub.overlay.header_center',
        'controlsFooterCenter': 'epub.overlay.footer_center',
      }.entries)
        PreferenceSpec(
          entry.key,
          entry.value,
          const {
                'readerHeaderCenter': 'bookTitle',
                'readerFooterLeading': 'chapterTitle',
                'readerFooterTrailing': 'chapterRemaining',
                'controlsHeaderCenter': 'bookProgressPercent',
                'controlsFooterCenter': 'chapterPosition',
              }[entry.key] ??
              'none',
          bucket: 'epubOverlay',
          section: 'Reader Overlay',
          choices: const {
            'none': 'epub.overlay.item.none',
            'bookTitle': 'epub.overlay.item.book_title',
            'chapterTitle': 'epub.overlay.item.chapter_title',
            'bookProgressPercent': 'epub.overlay.item.book_progress',
            'bookRemainingPercent': 'epub.overlay.item.book_remaining',
            'chapterProgressPercent': 'epub.overlay.item.chapter_progress',
            'chapterRemaining': 'epub.overlay.item.chapter_remaining',
            'chapterPosition': 'epub.overlay.item.chapter_page',
          },
        ),
      const PreferenceSpec(
        'showsReaderProgressBar',
        'Show Progress Bar While Reading',
        false,
        bucket: 'epubOverlay',
      ),
    ],
  );
}

class EpubThemeSettingsPage extends StatefulWidget {
  const EpubThemeSettingsPage({super.key, required this.repository});
  final Repository repository;
  @override
  State<EpubThemeSettingsPage> createState() => _EpubThemeSettingsPageState();
}

class _EpubThemeSettingsPageState extends State<EpubThemeSettingsPage> {
  static const _themeKeys = {
    'theme',
    'colorScheme',
    'font',
    'fontWeight',
    'advancedLayout',
    'fontSize',
    'lineHeight',
    'margin',
    'columns',
    'alignment',
    'paragraphSpacing',
    'indent',
    'letterSpacing',
    'wordSpacing',
  };
  Json _theme(dynamic value) => Map.fromEntries(
    object(value).entries.where((entry) => _themeKeys.contains(entry.key)),
  );
  LocalStore get store => widget.repository.store;
  CustomFontStore get fonts =>
      CustomFontStore(store, widget.repository.directory);
  Future<void> _savePreset() async {
    var draftName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'Save as Preset')),
        content: TextField(
          onChanged: (value) => draftName = value,
          maxLength: 80,
          decoration: InputDecoration(labelText: tr(context, 'Preset Name')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, draftName.trim()),
            child: Text(tr(context, 'Save')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final presets = (store.setting<List<dynamic>>('epubPresets') ?? [])
        .map(object)
        .where((entry) => entry['name'] != name)
        .toList();
    store.setSetting('epubPresets', [
      ...presets,
      {'name': name, 'value': _theme(store.setting<dynamic>('epubDefault'))},
    ]);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => PreferencePage(
    key: ValueKey(
      '${store.setting<dynamic>('epubDefault')}:${fonts.fonts.length}',
    ),
    title: 'EPUB Theme',
    store: store,
    header: Card(
      child: Column(
        children: [
          ListTile(
            title: Text(tr(context, 'Save as Preset')),
            onTap: _savePreset,
          ),
          for (final preset
              in (store.setting<List<dynamic>>('epubPresets') ?? []).map(
                object,
              ))
            ListTile(
              title: Text(text(preset['name'])),
              onTap: () => setState(
                () => store.setSetting('epubDefault', {
                  ...object(store.setting<dynamic>('epubDefault')),
                  ..._theme(preset['value']),
                }),
              ),
              trailing: IconButton(
                tooltip: tr(context, 'Delete'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(
                  () => store.setSetting(
                    'epubPresets',
                    (store.setting<List<dynamic>>('epubPresets') ?? [])
                        .where(
                          (value) => object(value)['name'] != preset['name'],
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
          ListTile(
            title: Text(tr(context, 'Import Font')),
            onTap: () async {
              try {
                await fonts.importFont();
                if (mounted) setState(() {});
              } catch (error) {
                if (context.mounted) showError(context, error);
              }
            },
          ),
          for (final font in fonts.fonts)
            ListTile(
              title: Text(text(font['name'])),
              trailing: IconButton(
                tooltip: tr(context, 'Delete'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await fonts.remove(text(font['id']));
                  if (mounted) setState(() {});
                },
              ),
            ),
        ],
      ),
    ),
    specs: [
      const PreferenceSpec(
        'colorScheme',
        'settings.appearance.colorScheme.title',
        'system',
        bucket: 'epubDefault',
        section: 'Theme',
        choices: {'system': 'System', 'light': 'Light', 'dark': 'Dark'},
      ),
      const PreferenceSpec(
        'theme',
        'Theme',
        'sepia',
        bucket: 'epubDefault',
        choices: {
          'system': 'System',
          'quiet': 'Quiet',
          'sepia': 'Sepia',
          'green': 'Green',
          'white': 'White',
          'black': 'Black',
        },
      ),
      PreferenceSpec(
        'font',
        'Typeface',
        'publisher',
        bucket: 'epubDefault',
        section: 'Font',
        choices: {
          'publisher': 'Publisher',
          'serif': 'Serif',
          'sans-serif': 'Sans Serif',
          for (final font in fonts.fonts)
            'custom:${font['id']}': text(font['name']),
        },
      ),
      const PreferenceSpec(
        'fontWeight',
        'Font Weight',
        0,
        bucket: 'epubDefault',
        min: 0,
        max: 900,
        step: 100,
        caption: 'Default',
      ),
      const PreferenceSpec(
        'columns',
        'Page Layout',
        0,
        bucket: 'epubDefault',
        section: 'Layout',
        choices: {0: 'Automatic', 1: 'Single Page', 2: 'Double Page'},
      ),
      const PreferenceSpec(
        'advancedLayout',
        'Advanced Layout',
        true,
        bucket: 'epubDefault',
      ),
      PreferenceSpec(
        'fontSize',
        'Font Size',
        19.0,
        bucket: 'epubDefault',
        min: 8,
        max: 60,
        step: 1,
        visible: _epubAdvanced,
      ),
      PreferenceSpec(
        'lineHeight',
        'Line Height',
        1.65,
        bucket: 'epubDefault',
        min: 1,
        max: 3,
        step: .05,
        visible: _epubAdvanced,
      ),
      const PreferenceSpec(
        'margin',
        'Page Margins',
        24.0,
        bucket: 'epubDefault',
        min: 0,
        max: 100,
        step: 2,
      ),
      PreferenceSpec(
        'paragraphSpacing',
        'Paragraph Spacing',
        .5,
        bucket: 'epubDefault',
        min: 0,
        max: 3,
        step: .1,
        visible: _epubAdvanced,
      ),
      PreferenceSpec(
        'indent',
        'Paragraph Indent',
        0.0,
        bucket: 'epubDefault',
        min: 0,
        max: 4,
        step: .1,
        visible: _epubAdvanced,
      ),
      PreferenceSpec(
        'letterSpacing',
        'Letter Spacing',
        0.0,
        bucket: 'epubDefault',
        min: -.05,
        max: .3,
        step: .01,
        visible: _epubAdvanced,
      ),
      PreferenceSpec(
        'wordSpacing',
        'Word Spacing',
        0.0,
        bucket: 'epubDefault',
        min: 0,
        max: 1,
        step: .05,
        visible: _epubAdvanced,
      ),
      PreferenceSpec(
        'alignment',
        'Text Alignment',
        'publisher',
        bucket: 'epubDefault',
        choices: {
          'publisher': 'Publisher',
          'left': 'Left',
          'right': 'Right',
          'justify': 'Justify',
          'center': 'Center',
        },
        visible: _epubAdvanced,
      ),
    ],
  );
}
