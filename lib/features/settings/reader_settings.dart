import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/reader_defaults.dart';
import '../../core/repository.dart';
import '../../core/store.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../reader/custom_fonts.dart';
import 'preference_controls.dart';
import 'settings_style.dart';
import '../reader/epub_session.dart';
import '../../ui/wheel_scroll.dart';

List<PreferenceSpec> pageMotionSpecs(
  String bucket, {
  bool Function(LocalStore)? visible,
}) => [
  PreferenceSpec(
    'followGesture',
    'motion.followGesture',
    true,
    bucket: bucket,
    visible: visible,
    caption: 'motion.followGesture.caption',
  ),
  PreferenceSpec(
    'animationDuration',
    'motion.duration',
    380,
    bucket: bucket,
    visible: visible,
    min: 150,
    max: 900,
    step: 10,
    formatValue: (n) => '${n.round()} ms',
  ),
  PreferenceSpec(
    'pageTint',
    'motion.tint',
    .10,
    bucket: bucket,
    visible: visible,
    min: 0,
    max: .25,
    step: .01,
    formatValue: (n) => '${(n * 100).round()}%',
  ),
  PreferenceSpec(
    'pageCornerRadius',
    'motion.corners',
    18.0,
    bucket: bucket,
    visible: visible,
    min: 0,
    max: 32,
    step: 1,
    formatValue: (n) => '${n.round()} px',
  ),
];

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

const transitionChoices = <Object, String>{
  'slide': 'reader.page_transition.scroll',
  'cover': 'reader.page_transition.cover',
  'curl': 'reader.page_transition.page_curl',
};

Json _comic(LocalStore store) =>
    object(store.setting<dynamic>('readerDefault'));
bool _comicAllowsWebtoon(LocalStore store) =>
    _comic(store)['useSeriesDirection'] != false ||
    _comic(store)['mode'] == 'webtoon';
bool _comicAllowsPaged(LocalStore store) =>
    _comic(store)['useSeriesDirection'] != false ||
    _comic(store)['mode'] != 'webtoon';
bool _comicHasTaps(LocalStore store) => _comic(store)['tapMode'] != 'none';
String _percent(num value) => '${value.round()}%';
String _scale(num value) => '${value.toStringAsFixed(1)}x';

class DivinaSettingsPage extends StatelessWidget {
  const DivinaSettingsPage({super.key, required this.repository});
  final Repository repository;
  void _changed(String key) {
    final settings = _comic(repository.store);
    if (key == 'pageLayout' && settings[key] == 'dual-forced') {
      updateReaderDefaults(repository.store, 'readerDefault', {
        'spread': true,
        'splitWide': 'none',
      });
    } else if (key == 'splitWide' && settings[key] != 'none') {
      updateReaderDefaults(repository.store, 'readerDefault', {
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
      PreferenceSpec(
        "direction",
        "Preferred Direction",
        "ltr",
        bucket: "readerDefault",
        section: "Default Reading Options",
        choices: {
          'ltr': 'Left to Right',
          'rtl': 'Right to Left',
          'vertical': 'Vertical',
          'webtoon': 'Webtoon',
        },
        caption:
            "Used when a book or series doesn't specify a reading direction",
        readValue: (store) =>
            const ['vertical', 'webtoon'].contains(_comic(store)['mode'])
            ? _comic(store)['mode'] as String
            : _comic(store)['direction'] as String? ?? 'ltr',
        writeValue: (store, value) =>
            updateReaderDefaults(store, 'readerDefault', {
              'mode': const ['ltr', 'rtl'].contains(value) ? 'paged' : value,
              'direction': value == 'rtl' ? 'rtl' : 'ltr',
            }),
        choiceIcons: {
          'ltr': Icons.last_page,
          'rtl': Icons.first_page,
          'vertical': Icons.south,
          'webtoon': Icons.view_day_outlined,
        },
      ),
      PreferenceSpec(
        "useSeriesDirection",
        "Force Default Reading Direction",
        true,
        bucket: "readerDefault",
        invertBool: true,
        caption: "Ignore book and series metadata and always use the preferred direction",
      ),
      PreferenceSpec(
        "pageLayout",
        "Page Layout",
        "single",
        bucket: "readerDefault",
        choices: {
          'single': 'reader.pageLayout.single',
          'auto': 'reader.pageLayout.auto',
          'dual-forced': 'reader.pageLayout.dual',
        },
        captionValue: (store) =>
            'reader.pageLayout.${const {'single': 'single', 'dual-forced': 'dual'}[_comic(store)['pageLayout']] ?? 'auto'}.detail',
        choiceIcons: {
          'single': Icons.crop_portrait,
          'auto': Icons.auto_awesome_outlined,
          'dual-forced': Icons.splitscreen_outlined,
        },
      ),
      PreferenceSpec(
        "splitWide",
        "Split Wide Pages",
        "none",
        bucket: "readerDefault",
        choices: {
          'none': 'None',
          'auto': 'Automatic',
          'ltr': 'Left to Right',
          'rtl': 'Right to Left',
          'scroll': 'reader.splitWidePage.scroll',
        },
        caption: "In single page mode, split landscape pages into two separate pages; Scroll keeps a spread whole and pans across it",
        visible: (store) => _comic(store)['pageLayout'] != 'dual-forced',
      ),
      PreferenceSpec(
        "soloCover",
        "Solo Cover Page",
        false,
        bucket: "readerDefault",
        caption:
            "Display the cover page separately, not paired with the next page",
        visible: (store) =>
            (_comic(store)['pageLayout'] ?? 'single') != 'single',
      ),
      PreferenceSpec(
        "background",
        "Reader Background",
        "black",
        bucket: "readerDefault",
        section: "Appearance",
        choices: backgroundChoices,
        caption: "The background color of the reader",
      ),
      PreferenceSpec(
        "showPageNumber",
        "Show Page Number",
        true,
        bucket: "readerDefault",
        caption: "Display page number overlay on images while reading",
      ),
      PreferenceSpec(
        "showPageShadow",
        "Show Page Shadow",
        false,
        bucket: "readerDefault",
        caption: "Render a subtle shadow around pages. Turn off for seamless dual-page spreads.",
      ),
      PreferenceSpec(
        "controlsGradient",
        "Controls Gradient Background",
        true,
        bucket: "readerDefault",
        caption: "Add a gradient behind reader controls for better contrast over pages.",
      ),
      PreferenceSpec(
        "showProgress",
        "Show Progress Bar While Reading",
        false,
        bucket: "readerDefault",
        caption: "Keep book progress pinned to the bottom until reader controls are shown.",
      ),
      PreferenceSpec(
        "webtoonWidth",
        "Webtoon Page Width",
        100.0,
        bucket: "readerDefault",
        min: 50,
        max: 100,
        step: 5,
        visible: _comicAllowsWebtoon,
        formatValue: _percent,
        caption:
            "Adjust the width of webtoon pages as a percentage of screen width",
      ),
      PreferenceSpec(
        "transition",
        "Page Transition Style",
        "cover",
        bucket: "readerDefault",
        section: "Page Turn",
        choices: transitionChoices,
        visible: _comicAllowsPaged,
        captionValue: (store) =>
            'reader.page_transition.${const {'cover': 'cover', 'curl': 'page_curl'}[_comic(store)['transition']] ?? 'scroll'}.description',
      ),
      ...pageMotionSpecs('readerDefault', visible: _comicAllowsPaged),
      PreferenceSpec(
        "animate",
        "Animate Page Turns",
        true,
        bucket: "readerDefault",
        caption: "Use animation when tapping zones to turn pages",
      ),
      PreferenceSpec(
        "tapMode",
        "Tap Zones",
        "default",
        bucket: "readerDefault",
        choices: tapChoices,
        caption: "Choose how tap zones are laid out",
      ),
      PreferenceSpec(
        "tapInversion",
        "Tap Zone Mirroring",
        "auto",
        bucket: "readerDefault",
        choices: inversionChoices,
        visible: _comicHasTaps,
        caption: "Mirror left and right tap zones manually or automatically for RTL reading",
      ),
      PreferenceSpec(
        "showTapHints",
        "Show Tap Zone Hints",
        false,
        bucket: "readerDefault",
        visible: _comicHasTaps,
        caption: "Display tap zone hints when opening the reader",
      ),
      PreferenceSpec(
        "tapScroll",
        "Webtoon Tap Scroll Height",
        80.0,
        bucket: "readerDefault",
        min: 25,
        max: 100,
        step: 5,
        visible: (store) => _comicHasTaps(store) && _comicAllowsWebtoon(store),
        formatValue: _percent,
        caption: "Scroll distance when tapping to navigate in webtoon mode",
      ),
      PreferenceSpec(
        "doubleTapEnabled",
        "Double Tap to Zoom",
        true,
        bucket: "readerDefault",
        section: "Zooming",
      ),
      PreferenceSpec(
        "doubleTapZoom",
        "Double Tap Zoom Scale",
        2.0,
        bucket: "readerDefault",
        min: 1,
        max: 8,
        step: 0.5,
        visible: (store) => _comic(store)['doubleTapEnabled'] != false,
        formatValue: _scale,
        caption: "Zoom level when double-tapping on a page",
      ),
      PreferenceSpec(
        "preload",
        "Image Preloading",
        "balanced",
        bucket: "readerDefault",
        section: "Performance",
        choices: {
          'lowMemory': 'Low Memory',
          'balanced': 'Balanced',
          'fastPageTurns': 'Fast Page Turns',
        },
        captionValue: (store) =>
            const {
              'lowMemory': 'Decode fewer nearby pages to reduce memory usage. Page turns may wait for loading more often.',
              'fastPageTurns': 'Keep more nearby pages decoded for smoother page turns at the cost of higher memory usage.',
            }[_comic(store)['preload']] ??
            'Use the default preloading window for a balance between memory usage and smooth page turns.',
      ),
      PreferenceSpec(
        "borderCrop",
        "Border Cropping",
        "disabled",
        bucket: "readerDefault",
        section: "Image Processing",
        choices: {
          'disabled': 'Disabled',
          'conservative': 'Conservative',
          'aggressive': 'Aggressive',
        },
        caption: "Automatically trim empty page borders.",
      ),
      PreferenceSpec(
        "imageUpscalingMode",
        "Waifu2x Mode",
        "disabled",
        choices: {'disabled': 'Disabled', 'auto': 'Automatic'},
        section: "Image Processing",
        caption: "Improve clarity for low-resolution pages using built-in waifu2x (2x).",
      ),
      PreferenceSpec(
        "imageUpscaleAutoTriggerScale",
        "Auto Trigger Scale Threshold",
        1.05,
        min: 1,
        max: 1.5,
        step: 0.01,
        visible: (store) =>
            store.setting<String>('imageUpscalingMode') == 'auto',
        formatValue: (value) => '${value.toStringAsFixed(2)}x',
        section: "Image Processing",
        caption: "Auto scale only when required scale to fit the page on screen is greater than this value.",
      ),
      PreferenceSpec(
        "liveText",
        "Enable Live Text",
        false,
        bucket: "readerDefault",
        section: "Live Text",
        caption: "Automatically enable Live Text for all images.",
      ),
      PreferenceSpec(
        "imageContextMenu",
        "Enable Image Context Menu",
        true,
        bucket: "readerDefault",
        section: "Context Menu",
        caption: 'settings.reader.contextMenu.port.caption',
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
    store: repository.store,
    onChanged: (key) {
      if (key == 'readListContinuationEnabled') {
        repository.readLists.setEnabled(
          repository.store.setting<bool>(key) == true,
        );
      }
      repository.changed();
    },
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
        caption: 'Unread and finished books record reading progress only after you turn this many pages. Books in progress record every page you turn.',
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
        section: 'settings.reader.nextBook',
        caption: 'settings.reader.suggestNextUnreadBook.caption',
      ),
      PreferenceSpec(
        'readListContinuationEnabled',
        'settings.dashboard.readListContinuation.title',
        false,
        section: 'Read Lists',
        caption: 'settings.dashboard.readListContinuation.caption',
      ),
      PreferenceSpec(
        'showKeyboardHelpOverlay',
        'Auto-Show Keyboard Help',
        true,
        section: 'Keyboard',
        caption: 'Briefly show keyboard shortcuts when opening the reader',
      ),
      PreferenceSpec(
        'spaceKeyAction',
        'reader.spaceKeyAction.title',
        'toggleControls',
        caption: 'reader.spaceKeyAction.caption',
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
        caption: 'Automatically enter full screen when opening the reader',
      ),
      PreferenceSpec(
        'keepScreenAwakeWhileReading',
        'Keep Screen Awake While Reading',
        false,
        caption: 'Prevents the screen from dimming or locking while a reader is open.',
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
        section: 'Rendering Engine',
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
        caption: 'Use animation when tapping zones to turn pages',
      ),
      PreferenceSpec(
        'transition',
        'Page Transition Style',
        'slide',
        bucket: 'epubDefault',
        choices: transitionChoices,
        visible: _epubPaged,
        captionValue: (store) =>
            'reader.page_transition.${const {'cover': 'cover', 'curl': 'page_curl'}[object(store.setting<dynamic>('epubDefault'))['transition']] ?? 'scroll'}.description',
      ),
      ...pageMotionSpecs('epubDefault', visible: _epubPaged),
      PreferenceSpec(
        'tapScroll',
        'epub.scrolled.tap_scroll_height',
        80.0,
        bucket: 'epubDefault',
        min: 25,
        max: 100,
        step: 5,
        visible: (store) => !_epubPaged(store),
        caption: 'epub.scrolled.tap_scroll_height.description',
        formatValue: _percent,
      ),
      const PreferenceSpec(
        'tapMode',
        'Tap Zones',
        'default',
        bucket: 'epubDefault',
        section: 'Tap Zones',
        caption: 'Choose how tap zones are laid out',
        choices: tapChoices,
      ),
      PreferenceSpec(
        'tapInversion',
        'Tap Zone Mirroring',
        'auto',
        visible: (store) =>
            object(store.setting<dynamic>('epubDefault'))['tapMode'] != 'none',
        caption: 'Mirror left and right tap zones manually or automatically for RTL reading',
        bucket: 'epubDefault',
        choices: inversionChoices,
      ),
      const PreferenceSpec(
        'epubShowsStatusBarWhileReading',
        'Show Status Bar While Reading',
        false,
        section: 'Reader Overlay',
        caption: 'Keep time and battery visible when controls are hidden.',
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
          section: entry.key.startsWith('controls')
              ? 'epub.overlay.controls'
              : 'epub.overlay.reading',
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
        section: 'epub.overlay.reading',
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

  Future<void> _loadPreset() async {
    final selected = await Navigator.push<Json>(
      context,
      MaterialPageRoute(
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) {
            final presets = (store.setting<List<dynamic>>('epubPresets') ?? [])
                .map(object)
                .toList();
            return SettingsScaffold(
              title: 'Theme Presets',
              body: ListView(
                padding: const EdgeInsets.all(22),
                children: [
                  if (presets.isEmpty)
                    const EmptyView(
                      title: 'No Theme Presets',
                      message: 'Save your favorite EPUB reading themes for quick access',
                    ),
                  if (presets.isNotEmpty)
                    const SettingsHeading('Saved Presets'),
                  Card(
                    child: Column(
                      children: [
                        for (final preset in presets)
                          ListTile(
                            title: Text(text(preset['name'])),
                            onTap: () => Navigator.pop(context, preset),
                            trailing: PopupMenuButton<String>(
                              onSelected: (action) async {
                                if (action == 'delete') {
                                  if (!await confirm(
                                    context,
                                    'Delete',
                                    text(preset['name']),
                                  )) {
                                    return;
                                  }
                                  store.setSetting(
                                    'epubPresets',
                                    presets
                                        .where(
                                          (p) => p['name'] != preset['name'],
                                        )
                                        .toList(),
                                  );
                                } else {
                                  var draft = text(preset['name']);
                                  final name = await showDialog<String>(
                                    context: context,
                                    builder: (dialog) => AlertDialog(
                                      title: Text(tr(dialog, 'Rename Preset')),
                                      content: TextFormField(
                                        initialValue: draft,
                                        maxLength: 80,
                                        onChanged: (value) => draft = value,
                                        decoration: InputDecoration(
                                          labelText: tr(dialog, 'Preset Name'),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dialog),
                                          child: Text(tr(dialog, 'Cancel')),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(
                                            dialog,
                                            draft.trim(),
                                          ),
                                          child: Text(tr(dialog, 'Rename')),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (name == null || name.isEmpty) return;
                                  if (presets.any(
                                    (p) =>
                                        p['name'] == name &&
                                        p['name'] != preset['name'],
                                  )) {
                                    return;
                                  }
                                  store.setSetting('epubPresets', [
                                    for (final p in presets)
                                      p['name'] == preset['name']
                                          ? {...p, 'name': name}
                                          : p,
                                  ]);
                                }
                                if (context.mounted) refresh(() {});
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text(tr(context, 'Rename')),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(tr(context, 'Delete')),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ).withWheelScrolling(),
            );
          },
        ),
      ),
    );
    if (selected != null) {
      updateReaderDefaults(store, 'epubDefault', _theme(selected['value']));
    }
    if (mounted) setState(() {});
  }

  Future<void> _manageFonts() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) => SettingsScaffold(
            title: 'Manage Custom Fonts',
            body: ListView(
              padding: const EdgeInsets.all(22),
              children: [
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(tr(context, 'Import Font')),
                        leading: const Icon(Icons.add),
                        onTap: () async {
                          try {
                            await fonts.importFont();
                            if (context.mounted) refresh(() {});
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
                              if (object(
                                    store.setting<dynamic>('epubDefault'),
                                  )['font'] ==
                                  'custom:${font['id']}') {
                                updateReaderDefaults(store, 'epubDefault', {
                                  'font': 'publisher',
                                });
                              }
                              if (context.mounted) refresh(() {});
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ).withWheelScrolling(),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _themePicker(BuildContext context) {
    final settings = object(store.setting<dynamic>('epubDefault'));
    final dark =
        settings['colorScheme'] == 'dark' ||
        settings['colorScheme'] != 'light' &&
            Theme.of(context).brightness == Brightness.dark;
    const themes = {
      'system': 'System',
      'quiet': 'Quiet',
      'sepia': 'Sepia',
      'green': 'Green',
    };
    Widget tile(String key) {
      final palette = epubThemePalette(key, dark);
      Color color(String value) =>
          Color(int.parse(value.substring(1), radix: 16) | 0xff000000);
      final selected = (settings['theme'] ?? 'sepia') == key;
      final preview = Container(
        height: 70,
        decoration: BoxDecoration(
          color: color(palette.$1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : const Color(0xff8e8e93).withValues(alpha: .3),
            width: selected ? 2 : 1,
          ),
        ),
        child: Center(
          child: Text(
            'Aa',
            style: TextStyle(fontSize: 24, color: color(palette.$2)),
          ),
        ),
      );
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Semantics(
            button: true,
            selected: selected,
            label: tr(context, themes[key]!),
            child: InkWell(
              onTap: () => setState(
                () =>
                    updateReaderDefaults(store, 'epubDefault', {'theme': key}),
              ),
              child: preview,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        children: [
          Row(children: [tile('system'), tile('quiet')]),
          Row(children: [tile('sepia'), tile('green')]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PreferencePage(
    title: 'EPUB Theme',
    store: store,
    header: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading('Presets'),
        Card(
          child: Column(
            children: [
              ListTile(
                title: Text(tr(context, 'Load Preset')),
                leading: const Icon(Icons.bookmark_outline),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: _loadPreset,
              ),
              const Divider(height: 1, indent: 20, endIndent: 20),
              ListTile(
                title: Text(tr(context, 'Save as Preset')),
                leading: const Icon(Icons.bookmark),
                onTap: _savePreset,
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
      ],
    ),
    sectionTrailing: {
      'Theme': [_themePicker(context)],
      'Font': [
        const Divider(height: 1, indent: 20, endIndent: 20),
        ListTile(
          title: Text(tr(context, 'Manage Custom Fonts')),
          leading: const Icon(Icons.text_fields),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _manageFonts,
        ),
      ],
    },
    specs: [
      const PreferenceSpec(
        'colorScheme',
        'settings.appearance.colorScheme.title',
        'system',
        bucket: 'epubDefault',
        section: 'Theme',
        choices: {'system': 'System', 'light': 'Light', 'dark': 'Dark'},
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
      PreferenceSpec(
        'fontWeightOverride',
        'Font Weight',
        false,
        bucket: 'epubDefault',
        readValue: (store) =>
            (object(store.setting<dynamic>('epubDefault'))['fontWeight']
                    as num? ??
                0) >
            0,
        writeValue: (store, value) => updateReaderDefaults(
          store,
          'epubDefault',
          {'fontWeight': value == true ? 400 : 0},
        ),
        caption: 'Font weight support depends on the current font. Some fonts may ignore this setting or only support part of the range.',
      ),
      PreferenceSpec(
        'fontWeight',
        'Font Weight',
        400,
        bucket: 'epubDefault',
        min: 100,
        max: 1000,
        step: 10,
        visible: (store) =>
            (object(store.setting<dynamic>('epubDefault'))['fontWeight']
                    as num? ??
                0) >
            0,
      ),
      const PreferenceSpec(
        'columns',
        'Page Layout',
        0,
        bucket: 'epubDefault',
        section: 'Page',
        choices: {0: 'Automatic', 1: 'Single Page', 2: 'Double Page'},
      ),
      PreferenceSpec(
        'margin',
        'Page Margins',
        24.0,
        bucket: 'epubDefault',
        min: 6,
        max: 48,
        step: 1.2,
        section: 'Page',
        formatValue: (value) => '${(value / 24).toStringAsFixed(2)}x',
      ),
      PreferenceSpec(
        'advancedLayout',
        'Advanced Layout',
        true,
        bucket: 'epubDefault',
        section: ' ',
        writeValue: (store, value) =>
            updateReaderDefaults(store, 'epubDefault', {
              'advancedLayout': value,
              'fontSize': 19.0,
              'wordSpacing': 0.0,
              'paragraphSpacing': .5,
              'indent': 2.0,
              'letterSpacing': 0.0,
              'lineHeight': 1.2,
              'alignment': 'publisher',
            }),
      ),
      PreferenceSpec(
        'fontSize',
        'Font Size',
        19.0,
        bucket: 'epubDefault',
        min: 4.75,
        max: 76,
        step: .95,
        section: 'Character & Word',
        formatValue: (value) => '${(value / 19).toStringAsFixed(2)}x',
        visible: _epubAdvanced,
      ),
      PreferenceSpec(
        'letterSpacing',
        'Letter Spacing',
        0.0,
        bucket: 'epubDefault',
        min: 0,
        max: 1,
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
        step: .01,
        visible: _epubAdvanced,
      ),
      PreferenceSpec(
        'alignment',
        'epub.text_alignment.title',
        'publisher',
        bucket: 'epubDefault',
        section: 'Line & Paragraph',
        caption: 'epub.text_alignment.justify.description',
        choices: {
          'publisher': 'Publisher',
          'left': 'Left',
          'right': 'Right',
          'justify': 'Justify',
          'center': 'Center',
        },
        visible: _epubAdvanced,
      ),
      PreferenceSpec(
        'lineHeight',
        'Line Height',
        1.65,
        bucket: 'epubDefault',
        min: .5,
        max: 2.5,
        step: .1,
        visible: _epubAdvanced,
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
        max: 8,
        step: .5,
        visible: _epubAdvanced,
      ),
    ],
  );
}
