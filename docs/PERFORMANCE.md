# EPUB and catalog performance audit in 0.8.3

The paginated EPUB hot path previously took a native screenshot, JPEG-encoded it,
sent its base64 bytes back into JavaScript, waited for several extra animation
frames and then awaited the cosmetic transition. Rapid input queued behind that
work. The new path animates the live clipped viewport, commits navigation before
the effect finishes and cancels the preceding effect on further input. There is
no native screenshot in the page-turn path. Settled chapter documents skip
repeated font/image waits; newly opened chapters retain those waits.

Reader operations share one queue, including resize, preferences, navigation,
search and late resource layout. Delayed coarse Epub.js locator reports retain
the committed character anchor. This matters particularly for large vertical
text when a paragraph spans pages. The Flutter WebView widget is reused across
locator notifications, and Windows skips unchanged native surface dimensions.
WebView renderer exits trigger bounded recreation/restoration; malformed native
screenshot data no longer throws an exception through the COM completion.

A public-domain Gutenberg Moby Dick EPUB (ebook 2701, downloaded 2026-10-30,
about 795 kB) was tested with publisher font, 19 px, 1.65 line spacing, 24 px
margins, automatic columns, sepia, paginated slide transitions. The same bundled
Epub.js/Chromium runtime, file, chapter and viewport were used for each comparison.
Each case discards two warm-up turns and records ten further turns. The old
Windows screenshot step is reproduced with Chromium's JPEG85 screenshot command.

| Viewport | 0.8.2 slide command median | 0.8.3 slide command median |
|---|---:|---:|
| 1044 × 720 | 416.7 ms | 33.3 ms |
| 390 × 780 | 400.2 ms | 33.3 ms |

These cloud measurements ([raw results](benchmarks/epub-0.8.3.json)) measure command completion, including the old
screenshot/animation waits. They are not native Windows/Android FPS, total input
latency or a guarantee for every book/device. Initial opening remained roughly
0.3–0.4 seconds in this browser fixture; the main gain is repeated page turns.
The reproducible tool is `tool/epub_benchmark.py`; use the same EPUB and chapter
with `--assets` pointing to the prior assets and `--capture` for the old path.

Two long-chapter browser stress checks exercise 48 unique forward positions,
all four transitions, a never-completing animation promise, concurrent resize/
preferences/turns, reduced motion and actual nonblank screenshot pixels. They
assert at most one active animation, bounded iframe count and no retained
transform. Collected JS heap grew by about 0.5–0.6 MiB over this short run
(using CDP metrics after collection, not the browser's coarse memory estimate).
That short bounded-growth check does not establish unlimited-session memory use.
Native integration adds the actual Dart page-turn controls, retained WebView
identity, 48 further turns and visible rendered glyphs. On Windows it also
crashes the WebView2 renderer deliberately and checks position/text restoration.
Native debug timings are diagnostic and are not release performance claims.

Catalog card preferences previously performed SQL and JSON decoding on every
option lookup. A versioned nine-value snapshot now reloads only after a settings
write. A 20,000-card lookup probe (180,000 option reads) dropped from 180,000 SQL
reads to nine; measured host loop time fell from about 650 ms to 13–17 ms.
Assertions use database counts and correct invalidation, not timing thresholds.

A separate [document-open probe](benchmarks/epub-open-0.8.3.json) records five sequential `EpubDocument.openAsync` calls on that complete EPUB in the Dart test VM. Opening takes 302 ms initially and 114–141 ms subsequently, while an 8 ms main-isolate heartbeat continues (largest observed callback gap 12.9 ms). This supports retaining the existing worker parsing approach; it does not measure native first paint, device frame times or OS scheduling under load.

The broader audit verified existing request coalescing, warm catalog reuse,
cache quotas/invalidation, reserved foreground network slots, cover decode
buckets, comic page preloading and isolate-based large JSON/EPUB parsing.
Covers retain their image future across rebuilds. The real Komga loopback probe
still makes zero additional HTTP requests over 20 warm visits. No extra global
scrolling machinery was introduced in this audit. Physical hardware frame-time
profiling and every Windows graphics driver remain outside this evidence.

# Windows mouse-wheel scrolling in 0.8.2

The [0.8.2 preview](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.8.2-preview.1) animates Windows wheel detents in application
browsing, settings, menus and forms. A scroll position owns one ticker for an
active wheel sequence, retargeting a critically damped simulation without
resetting its clock. Consecutive detents retain velocity and accumulate distance;
a reversal discards the previous pending destination. Destinations and carried
velocity are bounded so the animation cannot bounce beyond either content edge.
Idle positions have no running ticker or pending event queue.

The controller changes only wheel scrolling on Windows. Native touch and
precision-trackpad pan gestures, scrollbar dragging, programmatic navigation and
paginated reader gestures keep their separate handling. Windows reduced motion
uses immediate wheel updates. Android uses the original Flutter positions.
Each implicit view has its own scoped controller, including nested lists and
horizontal shelves. Catalog/log builders remain lazy; the stable bounded
Dashboard/settings layout from 0.8.1 is retained.

Ten new host checks exercise continuous position/velocity, high-rate input while
it is still arriving, reversal, both edges, nested propagation, Shift-wheel,
interruptions, reduced motion, content resizing and lazy item construction.
A native Windows check sends real WM_MOUSEWHEEL messages through the runner and
Flutter engine, verifies intermediate motion and reversal, and compares rendered
pixels under repeated outward input at both boundaries. Native test input exists
only in debug builds. All source-matched CI jobs pass; see [validation](VALIDATION.md).
This establishes animated behavior and boundary stability in the tested runtimes,
not a physical-device FPS benchmark or Apple pixel parity.

# Scrolling correction in 0.8.1

The [0.8.1 preview](https://github.com/LeValue/KMReader-Porting/releases/tag/v0.8.1-preview.1) corrects the mixed-shelf Dashboard regression:
a lazy vertical list disposed offscreen empty sections, then reconstructed tall
loading placeholders during upward scrolling. Shrinking those placeholders
could push the viewport down despite upward input. The bounded Dashboard now
retains each section's state and exact height. Horizontal shelves and unbounded
catalogs/logs retain lazy construction; bounded settings forms use the stable
section view. The app clamps scroll boundaries, suppresses stretch/glow and
keeps app-bar elevation constant at the top.

The Appearance language menu uses a fixed-size retained surface and fades
without resizing its rows. Locale updates wait for route removal, avoiding a
whole-app localization rebuild during dismissal. Shared short menus, sheets
and dialogs also deliver their result after closing.

Regression checks fail on the original 0.8.0 implementations and pass on this
release. Native Android/Windows checks cover mixed-shelf reverse traversal,
settings pixels at the upper wheel boundary and the real Appearance language
flow. These establish geometry/state/rendered-pixel behavior in the test
runtimes; physical device frame times and every GPU driver remain unmeasured.

The native gate also exposed vertical EPUB stage growth to chapter height when
inline sizing was cleared. The outer stage now stays at viewport height. Initial
readiness and page turns refresh actual geometry, and animated turns recover a
missed coarse locator from the uncovered viewport after snapshot removal. The
regressions exercise cleared inline height, delayed reporting and animated large
vertical text. WebViews with unavailable or stale caret hit testing use a
bounded DOM Range search for the first visible character in the mapped paragraph.
Browser fixtures disable/freeze that API and retain geometry/progress assertions.
Saved anchors and concurrent typography changes remain protected.

Exact source, native runs and downloaded-package hashes are in
[validation](VALIDATION.md).

## 0.2.0 performance and porting changes

The first Android preview was a Flutter debug build. The optimized preview is
an AOT-compiled release-mode build. A debug APK cannot establish release-mode
UI performance. Device frame times have not been measured in this cloud task;
near-instant first-time transfers cannot be guaranteed across arbitrary servers
and networks.

## Cache and loading boundaries

- Unvisited root tabs do not construct their catalog views or start requests.
  Visited tabs retain their state; inactive tab animations are disabled.
- Catalogs and book metadata reuse a bounded hot cache and persistent SQLite
  results. Entries are fresh for 30 seconds. Stale results appear immediately
  while one shared request revalidates them. Manual refresh and SSE invalidate
  freshness; changed responses notify the UI in small batches. Existing rows,
  loaded pagination and scroll positions remain visible during revalidation.
- Encoded images use a 32 MiB shared LRU and an atomic disk cache. Identical
  consumers share requests and byte objects, allowing Flutter's decoded-image
  cache to reuse work. Covers use physical-width decode buckets instead of
  decoding full-resolution originals. Reader/EPUB image decode widths retain
  zoom headroom without decoding arbitrary source widths.
- Four image request slots prioritize visible content. At most one speculative
  request runs at a time. A comic reader warms two forward items and one previous
  page, including decoded images. Navigation supersedes older preload loops;
  preloading never reports reading progress.
- Temporary image files target a 512 MiB disk budget, trimmed by recent use in
  the background. The cleanup action preserves downloaded books and progress.
  Explicit downloads and document originals are separate from this image budget.
- Catalog metadata is written in transactions, once per fetched batch. Repeated
  rendering reuses progress values and indexed counts instead of scanning and
  decoding the entire pending-progress/download tables per card.
- EPUB ZIP/package/index discovery runs in an isolate. Valid navigation titles
  avoid decompressing every chapter at open time; the spine remains authoritative
  and documents without a usable index retain heading-based fallback. Large API
  JSON responses also decode outside the UI isolate.

## Regression evidence

The local suite passed **38 tests**, with the real-server test skipped there and
then executed separately against disposable Komga 1.29.1. Coverage includes warm
request reuse, stale-while-revalidate behavior, foreground priority, byte limits,
disk cleanup, SQLite migration, account-scoped persistence, prefetch without
progress writes, and retained pagination/scroll after background refresh.

Mobile/desktop widget flows exercise library scope, theme/language selection and
section dragging. They assert that unvisited tabs make no requests and that
reordering sections does not refetch catalog data. Screenshot artifacts remain
review aids rather than an Apple-to-target pixel-parity baseline.

A real Komga **loopback** probe with three synthetic books measured one cold
catalog load at **85.897 ms** and a median warm load at **0.087 ms** over 20 repeats.
Those repeats made **zero additional HTTP requests**. This measures repository
reuse on the cloud host, not phone navigation latency, frame rates or a general
server benchmark. CI reruns this probe and may report different timings.

## Optimized Android preview delivery

`ORG_GRADLE_PROJECT_kmreaderPreview=true flutter build apk --release` selects the
separate `dev.levalue.kmreader.preview` application ID and `KMReader Preview`
label. It can coexist with the old debug-signed `dev.levalue.kmreader` app, so
installing this preview does not delete that app's local data. The server must
be configured in the new app.

The preview uses a retained development keystore outside the checkout through
git-ignored `android/key.properties`. Only its public certificate fingerprint
is tracked in `tool/preview-certificate.sha256`. Production signing remains a
separate configuration; no private key, password or real server credential is
committed or passed to the delivery workflow.

`tool/stage_preview.py` stages the XZ-compressed signed APK as an unreferenced
Git data blob and checks the base64 request size before uploading. It does not
commit a binary to any branch. The manual CI dispatch
accepts its blob ID and APK SHA256, runs tests/independent optimized compilation,
then checks the staged binary's hashes, signing certificate and alignment before
uploading and publishing it through the runner's repository token. Normal CI
artifacts labeled `android-release-unsigned` are compilation outputs; install
the signed APK from the preview release instead.

The [parity matrix](PARITY.md) remains the feature acceptance checklist. This
iteration does not establish complete functional or visual parity.


## 0.3.0 continuation

The reader now uses upstream Low Memory (1 before/3 after), Balanced (3/5) and
Fast Page Turns (5/7) preload windows. Transport and encoded-cache limits remain
bounded; a larger window does not bypass the image scheduler. TaskQueueStatus
SSE bursts no longer invalidate every catalog; content events retain the debounce.
Book sort aliases are translated to the book DTO fields rather than the distinct
series field names. Multi-column series/book-number sorting uses repeated query
parameters. A real-stream test covers cancellation of an idle download, and
conditional range tests cover unchanged, replaced and malformed partial responses.
These are transport/state checks, not measured frame times on the user's phone.

Cache invalidation now also tracks request generations. A refresh within the
same Windows clock tick invalidates a warm query, while its freshly fetched
replacement stays reusable without another request. The regression freezes the
clock and checks both guarantees.

## 0.4.0 reader compatibility

Page manifests already in the query cache select Komga PNG conversion before
transferring TIFF/JPEG2000 or another nonportable source. Without a manifest, a
short signature check detects unsupported bytes and coalesces the PNG conversion.
Converted pages reuse the hot/disk caches. New downloads store portable pages;
existing downloaded pages upgrade atomically when online and retain their original
bytes if conversion is unavailable. Prefetch and conversion never send progress.

The real Komga fixture now mixes PNG, TIFF and JPEG2000 in the same comic. The
client downloads it, disconnects and decodes the stored green/blue pages using
Flutter's actual image codec. Unit tests cover request coalescing, direct PNG
selection, existing-download upgrade and offline failure without data loss.

PDF layout and theme changes suppress progress writes while restoring the same
canonical page. EPUB supplementary resources keep their scroll state separate from
canonical chapter progression; returning to the chapter restores that position.
The reader retains the current decoded HTML between rebuilds. Font-size dragging
updates the slider immediately and performs the document reflow on release,
avoiding a complete layout for each pointer movement.
Native PDF widget tests exercise real PDFium, including AES-128 password retry,
text search, result retention across viewport changes, whole-spread fitting and
canonical focus on the last spread without falsely advancing to the last page.
These checks do not substitute for frame-time or touch/zoom acceptance on a phone.

## 0.4.1 comic gestures and immersive Android reading

A single recognizer now arbitrates one-finger paging, multi-touch zoom and zoomed
panning. A second contact cancels an unfinished page turn even after crossing
the midpoint; the remaining finger cannot restart paging until all contacts lift.
Mouse-wheel zoom is retained. Vertical items stay alive during an active drag.

Adjacent pager items are prepared before a turn. Normal raster decoding targets
physical display width instead of twice that width for unsplit pages (one quarter
of decoded pixel area for uncapped images). Split wide pages retain the extra
width needed to display each half sharply. Only the visible page requests zoom headroom after
the gesture ends, with gapless image replacement. Page subtrees and reader theme
are reused; progress writes and additional preload work wait for scrolling to stop.

Android uses WindowInsetsController on API 30+ and immersive sticky flags on older
versions, with reader-specific cutout handling and restoration on exit. Page content
extends to the viewport edges while SafeArea surrounds controls only. Full Screen
hides controls; the separate Fill Screen choice explicitly crops page edges.

Gesture tests cover LTR/RTL paging, late pinch cancellation, pan after lifting one
finger, zoom reset, desktop wheel zoom, reuse of the rendered subtree, deferred
progress, full viewport size with simulated insets, vertical recycling, and
system-UI ownership/restoration. Physical Android frame times and OEM system-bar
behavior still require target-device acceptance.

## 0.5.0 notch handling and remaining reader preferences

Android reports stable system-bar and physical display-cutout insets separately.
Reader titles, controls and sheets use their maximum even if Flutter reports zero
padding after immersive mode hides the bars. EPUB/PDF AppBars receive the same
safe MediaQuery. The comic surface excludes only the actual notch, retaining
system-bar space; users can explicitly extend page content into the cutout.
Rotation replaces the old edges rather than accumulating portrait padding.
The global-layout observer is reader-scoped and emits only changed inset maps;
it does not replace Flutter's rendering-view WindowInsets listener.

Optional border cropping follows upstream conservative/aggressive pixel thresholds,
padding and retained-area safeguards. It decodes an analysis raster at 40% or less,
capped at 1024 pixels on its longest edge. The pixel scan runs in an isolate;
original encoded files remain untouched, and layout clips the original image
without encoding a second full-size PNG. Analysis futures are weakly associated
with shared byte objects, so reused adjacent pages avoid repeated analysis without
an unbounded cache. The disabled default bypasses analysis entirely.

Double-tap zoom is configurable from 1x to 8x. The dashboard's seven ordinary
sections now match upstream section types and card-size choices. Recently Released
uses a calendar-day month cutoff to preserve query-cache reuse throughout a day.
Changing a card style reuses catalog data. The optional Read Lists in Progress
section and other matrix gaps remain separate outstanding work.

The local suite passes 96 tests plus one deliberately skipped live case. New
checks cover zero Flutter padding, physical-to-logical inset conversion, landscape
notches, opt-in full-display content with protected controls, document AppBars,
actual cropped pixels, vertical crop geometry, configured double-tap zoom,
month-end cutoffs, and card-style persistence without HTTP refetches.
These checks do not measure frame times or validate OEM window behavior on a phone.
