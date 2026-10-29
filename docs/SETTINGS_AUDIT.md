# Upstream settings audit

Reference: [kmworks/kmreader](https://github.com/kmworks/kmreader/tree/e2b35f8796cc830fc6e7464e161b2172d8f916e9) at `e2b35f8796cc830fc6e7464e161b2172d8f916e9`.

The extraction records **128 persisted keys/structured fields**, **227 control declarations** and SHA256 hashes for **47 source files**. These are not 128 independent preferences: composite objects, account state, repeated platform controls and actions are included.

The extractor scans settings, nested translation/provider/model views, EPUB overlay/preset/font views and their persisted models. Button declarations are an audit aid, not proof of equivalent behavior. Values and source line origins are in [the inventory](upstream-settings.json); the machine-readable implementation map is [here](upstream-settings-support.json).

```sh
python3 tool/extract_upstream_settings.py /path/to/kmreader --output docs/upstream-settings.json --check
python3 -m unittest discover -s tool/tests
```

The original inventory shipped in 0.7.0. The 0.8.0 implementation adds grouped settings matching the reference order, captions, inline/adaptive pickers, conditional controls, preset/font subpages and reading-statistics charts. Exact verification is recorded in [validation](VALIDATION.md).

## Current coverage

**9 adapted**, **105 implemented**, **3 internal**, **5 partial**, **6 platform-unavailable**. Implemented means the control has a corresponding runtime effect; it does not assert pixel parity, matching defaults or verified native behavior. See [validation](VALIDATION.md).

The remaining original model-library functionality is **partial**: catalog URL editing, catalog downloads, independent model-role selection, archive download/deletion and Core ML recognizers are not ported. The application shows the actual bundled ONNX bubble detector and native OCR languages, with an explicit compatibility explanation. It does not offer dummy selectors for those archives.

Handoff, Spotlight and Live Activities have no implementation on these operating systems. Apple StoreKit subscriptions/tips, App Store review and Apple EULA navigation are also excluded; Android/Windows distribution is outside the Apple store. No paid entitlement gate has been introduced.

## Actions and presentation

- Appearance: system/light/dark, language, classic wide navigation, preview/capture privacy and the three original launcher icons. Android changes launcher components; Windows changes its window/taskbar icon, not arbitrary existing shortcuts.
- Browse: all nine original card/search switches, previews and immediate updates.
- Dashboard: section visibility/order/reset, card-kind menu and gradient. Library scope selects any subset or all libraries, including See All queries and batch selection.
- Reader general: offline-first preparation, confirmed automatic completed-download removal, threshold, next unread, list continuation, keyboard help/Space action, fullscreen and keep-awake. Removal waits for the last non-incognito reader to release files.
- DIVINA: direction, metadata override, layouts/cover/splitting, appearance, tap gestures, zoom, Webtoon width/scroll, preload, crop, Waifu2x and text/context-menu actions. Curl is a portable snapshot effect for discrete turns; swipe remains slide. Live Text opens selectable native OCR text. Context actions offer either spread page solo and PNG export through the system document picker; this adapts Apple sharing-sheet behavior.
- PDF: native/raster engine, all four raster qualities, direction/metadata, presentation/cover, background, gradient and progress.
- EPUB: flow/animation/transition/tap zones/status bar/percentage scrolling, eight overlay slots and progress; original theme families, color scheme, font weight, typography/columns/alignment/margins, custom font import/removal and named preset save/apply/rename/delete. Native HTML fallback does not have browser-engine feature parity. Fixed-layout publications retain authored CSS.
- Translation: provider add/edit/select/delete, secure key replacement/removal, model discovery/selection, source and target language, system target, metadata opt-in, translation visibility/direction and translation-cache removal. Bubble grouping uses the bundled detector.
- Cache: independent page/cover quotas, cover expiry, current-server counts/size, clear current/all accounts; downloaded originals and progress are retained. Cache totals are bounded across accounts. The document-cache controls from the existing port are retained.
- Network and real time: request/download/authentication timeout and safe-read retries; SSE enable/automatic refresh/in-app notices. Mutations are never automatically replayed. Turning SSE off cancels even a request still awaiting response headers.
- Logs/about/account/server: local bounded diagnostic search/filter/export/clear, version/licenses/documentation/community links, saved account management and existing Komga server/library/password/API-key actions. Diagnostic logs deliberately omit request addresses, credentials, payloads and book text; they are not a complete Apple OS log replica.

## Persistence and default differences

Existing installations retain saved preferences and legacy fallbacks. New installations seed original auto layout, system backgrounds, solo cover, page shadow, tap hints, zoom 3, progress threshold 3 and EPUB publisher typography. Changing a global reader preference now removes only that preference from older per-book snapshots, across accounts, while retaining locators, progress and unrelated choices. In-reader edits still save per-book snapshots; they do not update upstream-style global AppStorage.

EPUB theme sliders display original scale units and ranges; the browser adapter converts them to CSS px/em. The native HTML fallback remains reduced and is not equivalent to Readium. Original layout structure is used for the global settings forms; Android/Windows controls, fonts, compact-width adaptation and Apple-only options still differ.

Next-unread navigation requests `skipRead`, with an older-server fallback over locally known siblings and offline ordered-list continuation. Source-equivalent series-level Continue Reading selection remains open.

## Persisted-key mapping

| Original key or field | Status | Port storage | Runtime implementation |
| --- | --- | --- | --- |
| `DashboardConfiguration.cardKindOverrides` | implemented | `dashboardCard:<account>:<section>` | [dashboard.dart](../lib/features/catalog/dashboard.dart) |
| `DashboardConfiguration.libraryIds` | implemented | `dashboardLibrary:<account>` | [dashboard.dart](../lib/features/catalog/dashboard.dart) |
| `DashboardConfiguration.sections` | implemented | `dashboardHidden:<account> / dashboardOrder:<account>` | [settings_page.dart](../lib/features/settings/settings_page.dart) |
| `EpubOverlayPreferences.controlsFooterCenter` | implemented | `epubOverlay.controlsFooterCenter` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubOverlayPreferences.controlsHeaderCenter` | implemented | `epubOverlay.controlsHeaderCenter` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubOverlayPreferences.readerFooterCenter` | implemented | `epubOverlay.readerFooterCenter` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubOverlayPreferences.readerFooterLeading` | implemented | `epubOverlay.readerFooterLeading` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubOverlayPreferences.readerFooterTrailing` | implemented | `epubOverlay.readerFooterTrailing` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubOverlayPreferences.readerHeaderCenter` | implemented | `epubOverlay.readerHeaderCenter` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubOverlayPreferences.readerHeaderLeading` | implemented | `epubOverlay.readerHeaderLeading` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubOverlayPreferences.readerHeaderTrailing` | implemented | `epubOverlay.readerHeaderTrailing` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubOverlayPreferences.showsReaderProgressBar` | implemented | `epubOverlay.showsReaderProgressBar` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `EpubThemePreferences.advancedLayout` | implemented | `epubDefault.advancedLayout` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.colorScheme` | implemented | `epubDefault.colorScheme` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.columnCount` | implemented | `epubDefault.columns` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.fontFamily` | implemented | `epubDefault.font` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.fontSize` | adapted | `epubDefault.fontSize` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.fontWeight` | implemented | `epubDefault.fontWeight` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.letterSpacing` | implemented | `epubDefault.letterSpacing` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.lineHeight` | implemented | `epubDefault.lineHeight` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.pageMargins` | implemented | `epubDefault.margin` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.paragraphIndent` | implemented | `epubDefault.indent` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.paragraphSpacing` | implemented | `epubDefault.paragraphSpacing` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.textAlignment` | implemented | `epubDefault.alignment` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.theme` | implemented | `epubDefault.theme` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `EpubThemePreferences.wordSpacing` | implemented | `epubDefault.wordSpacing` | [epub_session.dart](../lib/features/reader/epub_session.dart) |
| `MangaProviderConfig.apiKey` | implemented | `credential vault translation:<id>` | [translation.dart](../lib/core/translation.dart) |
| `MangaProviderConfig.baseURL` | implemented | `translationProviders[].base` | [translation.dart](../lib/core/translation.dart) |
| `MangaProviderConfig.displayName` | implemented | `translationProviders[].name` | [translation.dart](../lib/core/translation.dart) |
| `MangaProviderConfig.model` | implemented | `translationProviders[].model` | [translation.dart](../lib/core/translation.dart) |
| `MangaTranslationPreferences.includeMetadata` | implemented | `translationIncludeMetadata` | [reader_text_page.dart](../lib/features/reader/reader_text_page.dart) |
| `MangaTranslationPreferences.selectedProviderID` | implemented | `translationProvider` | [reader_text_page.dart](../lib/features/reader/reader_text_page.dart) |
| `MangaTranslationPreferences.showTranslation` | implemented | `translationShow` | [reader_text_page.dart](../lib/features/reader/reader_text_page.dart) |
| `MangaTranslationPreferences.sourceLanguage` | implemented | `translationSource` | [reader_text_page.dart](../lib/features/reader/reader_text_page.dart) |
| `MangaTranslationPreferences.targetLanguage` | implemented | `translationTarget` | [reader_text_page.dart](../lib/features/reader/reader_text_page.dart) |
| `MangaTranslationPreferences.textDirection` | implemented | `translationTextDirection` | [reader_text_page.dart](../lib/features/reader/reader_text_page.dart) |
| `ModelLibraryConfiguration.catalog` | partial | `bundled bubble detector + native OCR languages` | [recognition_models_page.dart](../lib/features/settings/recognition_models_page.dart) |
| `ModelLibraryConfiguration.catalogURL` | partial | `bundled bubble detector + native OCR languages` | [recognition_models_page.dart](../lib/features/settings/recognition_models_page.dart) |
| `ModelLibraryConfiguration.downloadedArchives` | partial | `bundled bubble detector + native OCR languages` | [recognition_models_page.dart](../lib/features/settings/recognition_models_page.dart) |
| `ModelLibraryConfiguration.selectedStorageKeys` | partial | `bundled bubble detector + native OCR languages` | [recognition_models_page.dart](../lib/features/settings/recognition_models_page.dart) |
| `animateEpubTapTurns` | implemented | `epubDefault.animate` | [epub_reader.dart](../lib/features/reader/epub_reader.dart) |
| `animateTapTurns` | implemented | `readerDefault.animate` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `apiRetryCount` | implemented | `same key` | [network_preferences.dart](../lib/core/network_preferences.dart) |
| `appColorScheme` | implemented | `theme` | [app_controller.dart](../lib/core/app_controller.dart) |
| `authTimeout` | implemented | `same key` | [network_preferences.dart](../lib/core/network_preferences.dart) |
| `autoFullscreenOnOpen` | implemented | `same key` | [reader_display.dart](../lib/features/reader/reader_display.dart) |
| `cardTextOverlayMode` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `coverCacheExpirationDays` | implemented | `same key` | [media_cache.dart](../lib/core/media_cache.dart) |
| `coverOnlyCards` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `currentAccount` | internal | `active server / credential vault` | [app_controller.dart](../lib/core/app_controller.dart) |
| `dashboard` | implemented | `dashboardHidden:<account> / dashboardOrder:<account>` | [settings_page.dart](../lib/features/settings/settings_page.dart) |
| `defaultReadingDirection` | implemented | `readerDefault.direction` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `divinaPageBorderCropMode` | implemented | `readerDefault.borderCrop` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `divinaPreloadProfile` | implemented | `readerDefault.preload` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `doubleTapZoomMode` | implemented | `readerDefault.doubleTapEnabled` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `doubleTapZoomScale` | implemented | `readerDefault.doubleTapZoom` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `downloadTimeout` | implemented | `same key` | [network_preferences.dart](../lib/core/network_preferences.dart) |
| `enableBrowseHandoff` | platform-unavailable | `unavailable` | [system_features_page.dart](../lib/features/settings/system_features_page.dart) |
| `enableDivinaImageContextMenu` | implemented | `readerDefault.imageContextMenu` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `enableLiveText` | adapted | `readerDefault.liveText` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `enableReaderHandoff` | platform-unavailable | `unavailable` | [system_features_page.dart](../lib/features/settings/system_features_page.dart) |
| `enableReaderLiveActivity` | platform-unavailable | `unavailable` | [system_features_page.dart](../lib/features/settings/system_features_page.dart) |
| `enableSSE` | implemented | `same key` | [repository.dart](../lib/core/repository.dart) |
| `enableSSEAutoRefresh` | implemented | `same key` | [repository.dart](../lib/core/repository.dart) |
| `enableSSENotify` | implemented | `same key` | [repository.dart](../lib/core/repository.dart) |
| `enableSpotlightBookIndexing` | platform-unavailable | `unavailable` | [system_features_page.dart](../lib/features/settings/system_features_page.dart) |
| `enableSpotlightIndexing` | platform-unavailable | `unavailable` | [system_features_page.dart](../lib/features/settings/system_features_page.dart) |
| `enableSpotlightSeriesIndexing` | platform-unavailable | `unavailable` | [system_features_page.dart](../lib/features/settings/system_features_page.dart) |
| `epubFlowStyle` | implemented | `epubDefault.flow` | [epub_reader.dart](../lib/features/reader/epub_reader.dart) |
| `epubOverlayPreferences` | implemented | `epubOverlay` | [epub_overlay.dart](../lib/features/reader/epub_overlay.dart) |
| `epubPageTransitionStyle` | implemented | `epubDefault.transition` | [epub_reader.dart](../lib/features/reader/epub_reader.dart) |
| `epubRenderingEngine` | adapted | `epubRenderingEngine` | [document_readers.dart](../lib/features/reader/document_readers.dart) |
| `epubShowsStatusBarWhileReading` | adapted | `epubShowsStatusBarWhileReading` | [reader_display.dart](../lib/features/reader/reader_display.dart) |
| `epubTapScrollPercentage` | implemented | `epubDefault.tapScroll` | [epub_reader.dart](../lib/features/reader/epub_reader.dart) |
| `epubTapZoneInversionMode` | implemented | `epubDefault.tapInversion` | [epub_reader.dart](../lib/features/reader/epub_reader.dart) |
| `epubTapZoneMode` | implemented | `epubDefault.tapMode` | [epub_reader.dart](../lib/features/reader/epub_reader.dart) |
| `forceDefaultReadingDirection` | implemented | `readerDefault.useSeriesDirection (inverse)` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `imageUpscaleAutoTriggerScale` | implemented | `same key` | [page_upscaler.dart](../lib/features/reader/page_upscaler.dart) |
| `imageUpscalingMode` | implemented | `same key` | [page_upscaler.dart](../lib/features/reader/page_upscaler.dart) |
| `isLoggedInV2` | internal | `active server / credential vault` | [app_controller.dart](../lib/core/app_controller.dart) |
| `isolateCoverPage` | implemented | `readerDefault.soloCover` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `keepScreenAwakeWhileReading` | implemented | `same key` | [reader_display.dart](../lib/features/reader/reader_display.dart) |
| `mangaTranslation` | implemented | `translation* keys` | [translation_settings.dart](../lib/features/settings/translation_settings.dart) |
| `maxCoverCacheSize` | implemented | `same key` | [media_cache.dart](../lib/core/media_cache.dart) |
| `maxPageCacheSize` | implemented | `same key` | [media_cache.dart](../lib/core/media_cache.dart) |
| `modelLibrary` | partial | `bundled bubble detector + native OCR languages` | [recognition_models_page.dart](../lib/features/settings/recognition_models_page.dart) |
| `offlineAutoDeleteRead` | implemented | `same key` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `offlineFirstReading` | implemented | `same key` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `pageLayout` | implemented | `readerDefault.pageLayout` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `pageTransitionStyle` | adapted | `readerDefault.transition` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `pdfDefaultReadingDirection` | implemented | `pdfDefault.rtl` | [pdf_reader.dart](../lib/features/reader/pdf_reader.dart) |
| `pdfForceDefaultReadingDirection` | implemented | `pdfDefault.useSeriesDirection (inverse)` | [pdf_reader.dart](../lib/features/reader/pdf_reader.dart) |
| `pdfIsolateCoverPage` | implemented | `pdfDefault.coverSolo` | [pdf_reader.dart](../lib/features/reader/pdf_reader.dart) |
| `pdfOfflineRenderQuality` | implemented | `same key` | [pdf_reader_settings.dart](../lib/features/settings/pdf_reader_settings.dart) |
| `pdfPagePresentation` | implemented | `pdfDefault.presentation` | [pdf_reader.dart](../lib/features/reader/pdf_reader.dart) |
| `pdfReaderBackground` | implemented | `pdfDefault.background` | [pdf_reader.dart](../lib/features/reader/pdf_reader.dart) |
| `privacyProtection` | adapted | `privacyProtection` | [device_lock_gate.dart](../lib/ui/device_lock_gate.dart) |
| `progressRecordingThreshold` | implemented | `progressRecordingThreshold` | [progress_gate.dart](../lib/features/reader/progress_gate.dart) |
| `readListContinuationEnabled` | implemented | `readListContinuationEnabled` | [read_list_reading.dart](../lib/core/read_list_reading.dart) |
| `readerBackground` | implemented | `readerDefault.background` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `requestTimeout` | implemented | `same key` | [network_preferences.dart](../lib/core/network_preferences.dart) |
| `searchIgnoreFilters` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `showBookCardSeriesTitle` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `showDashboardCardKindMenu` | implemented | `same key` | [dashboard.dart](../lib/features/catalog/dashboard.dart) |
| `showDashboardSectionGradientBackground` | implemented | `same key` | [dashboard.dart](../lib/features/catalog/dashboard.dart) |
| `showDivinaControlsGradientBackground` | implemented | `readerDefault.controlsGradient` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `showDivinaProgressBarWhileReading` | implemented | `readerDefault.showProgress` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `showKeyboardHelpOverlay` | adapted | `showKeyboardHelpOverlay` | [reader_display.dart](../lib/features/reader/reader_display.dart) |
| `showPageNumber` | implemented | `readerDefault.showPageNumber` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `showPageShadow` | implemented | `readerDefault.showPageShadow` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `showPdfControlsGradientBackground` | implemented | `pdfDefault.controlsGradient` | [pdf_reader.dart](../lib/features/reader/pdf_reader.dart) |
| `showPdfProgressBarWhileReading` | implemented | `pdfDefault.showProgress` | [pdf_reader.dart](../lib/features/reader/pdf_reader.dart) |
| `showTapZoneHints` | implemented | `readerDefault.showTapHints` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `spaceKeyAction` | implemented | `spaceKeyAction` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `splitWidePageMode` | implemented | `readerDefault.splitWide` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `suggestNextUnreadBook` | adapted | `same key` | [next_book.dart](../lib/core/next_book.dart) |
| `tapZoneInversionMode` | implemented | `readerDefault.tapInversion` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `tapZoneMode` | implemented | `readerDefault.tapMode` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `taskQueueStatus` | internal | `live task queue` | [repository.dart](../lib/core/repository.dart) |
| `thumbnailBlurUnreadCovers` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `thumbnailPreserveAspectRatio` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `thumbnailShowProgressBar` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `thumbnailShowShadow` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `thumbnailShowUnreadIndicator` | implemented | `same key` | [browse_preferences.dart](../lib/core/browse_preferences.dart) |
| `useClassicPadNavigation` | adapted | `useClassicPadNavigation` | [shell.dart](../lib/ui/shell.dart) |
| `useNativePdfReader` | implemented | `same key` | [pdf_reader_settings.dart](../lib/features/settings/pdf_reader_settings.dart) |
| `webtoonPageWidthPercentage` | implemented | `readerDefault.webtoonWidth` | [reader_page.dart](../lib/features/reader/reader_page.dart) |
| `webtoonTapScrollPercentage` | implemented | `readerDefault.tapScroll` | [reader_page.dart](../lib/features/reader/reader_page.dart) |

Field-specific adaptations are recorded in `note` entries in the support JSON. The audit preserves outstanding gaps instead of declaring complete upstream parity.
