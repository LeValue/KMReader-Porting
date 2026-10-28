# Functional and visual parity

Reference: kmworks/kmreader `e2b35f8796cc830fc6e7464e161b2172d8f916e9`.
This matrix distinguishes implemented behavior from full upstream parity.

| Area | Implemented | Remaining work |
| --- | --- | --- |
| Authentication | Password, API key, first-server claim, account-scoped profiles, OS credential vault; optional device biometrics/PIN/Windows Hello app lock with cold-start and background protection | Device-level vault and OS authentication acceptance |
| Server management | Add, reconnect, switch, remove; isolated caches/files/outbox | More server editing and protection options |
| Dashboard | Keep Reading, On Deck, new books/series, updated series, recently read and recently released books; hide/reorder sections, persistent library scope, matching See All filters/sort, opt-in ordered read-list continuation with upstream-compatible client-settings sync and durable stop tombstones, compact empty sections, persistent large/medium/small/horizontal card styles | Native acceptance for read-list continuation |
| Catalog | Paginated series/books, submitted search, library browser, sort/read-status and nested typed metadata filters, per-account saved filters, selection of loaded items or all matching paginated results, batch read/unread/download/list actions; account-scoped SQLite FTS metadata index with full snapshot preparation, Unicode search, nested filters, sorts and local progress | Every upstream card/sort/filter presentation; offline special-list and On Deck parity |
| Details and lists | Covers, metadata/summary, read/unread, collections/read lists; metadata editing with field locks and explicit batch changes; nonempty list creation, membership editing/reordering/deletion, personal pins; kmrs server smart-list CRUD, visibility and admin sharing, preserving uneditable conditions | Custom thumbnails, all detail layouts, real kmrs smart-list/sharing acceptance tests |
| Comic reader | Portable raster pages and cached Komga PNG conversion for TIFF/JPEG2000 and other formats, inherited series reading direction, unified pinch/paging arbitration, idle progress/preload work, adaptive decode resolution, Android immersive display with native notch-safe controls/sheets and page bounds in either orientation, explicit cutout extension, conservative/aggressive border cropping, configurable double-tap zoom, optional cropped screen fill, paged/LTR/RTL, vertical/Webtoon, spreads, zoom, rotation, backgrounds, six upstream tap-zone presets with inversion, three preload windows, animation toggle, optional automatic original-model Waifu2x upscaling, split wide pages in LTR/RTL/automatic order with semantic progress and half-page resume, height-fitted wide-page panning with saved pan positions, rotation restoration and gesture ownership/edge turns, GPU cover/slide transitions, incognito and continuation | Curl animation, device frame-time/memory acceptance |
| PDF | PDFium viewer, text search/highlights after document readiness, outline, jump/resume, auto/paged/continuous/single/dual layouts, cover-alone and RTL options, themes, password retry without persistence, original-file offline reading | Quality presets/offline raster rendering, DIVINA alternative, exact upstream gesture/animation behavior, device acceptance |
| EPUB | Native Android WebView / Windows WebView2 with bundled Epub.js, ZIP resource serving and decompression in a worker isolate; paged/scrolled reading, CFI resume and remote progression, hierarchical EPUB 2/3 contents, search/bookmarks, supplementary footnotes, columns, spacing/alignment/themes, author CSS and embedded fonts, imported TTF/OTF/WOFF fonts, IDPF/Adobe font deobfuscation, UTF-16 resources, six tap-zone presets, slide/cover/curl overlays, incognito, next-book continuation | CJK/vertical and fixed-layout edge cases, continuous cross-chapter scroll, selection/dictionary/translation tools, exact upstream typography and native gesture/performance acceptance |
| Downloads | Streaming originals and portable comic pages (including conversion/upgrade of unsupported raster formats), disk persistence, deduplicated queue with 1–3 active transfers, cancel/retry/remove, automatic resume after restart, validated HTTP range/If-Range transfer resume, cross-process SQLite transfer leases, account-deletion tombstones, Android WorkManager / hidden Windows Task Scheduler workers, unmetered/charging rules, offline reading | Android OS scheduling acceptance, archive pages on demand, disk quotas/cleanup UX, large-queue stress tests |
| Progress | Durable coalesced outbox, revision acknowledgements, retained failures, newer-remote conflict resolution | More multi-device/reconnect/device-clock stress tests; parity for every reader transition |
| Live updates | SSE subscription, debounced refresh and reconnect | Full event-specific invalidation and real SSE acceptance tests |
| Cache/performance | Persistent catalog reuse with 30-second freshness and background revalidation, request coalescing, 8 MiB hot query/32 MiB encoded-image budgets, 512 MiB temporary-image disk target and cleanup, versioned EPUB/PDF source cache with conditional HEAD revalidation and configurable 128 MiB–8 GiB quota (1 GiB default), protection of active and downloaded originals, lazy tab initialization, batched SQL writes, background EPUB indexing | Device frame-time/performance acceptance, conditional thumbnail/page revalidation, advanced preload policies |
| Settings | Theme, original ten-language catalog, dashboard sections, offline mode, downloads, server info | Some new labels/errors still need translations; full upstream preference surface |
| API keys | List/create/copy/revoke, optional automatically created and independently verified key on password login, password fallback for unsupported servers, identification/protection of the managed active key | Manual-key identity discovery, authentication/session history, target-vault acceptance |
| Administration | Library creation/editing with all creation DTO options, server-folder browser, optimistic edit checks, scan/deep scan/analyze/metadata refresh/empty trash/removal; metadata editors | Duplicate detection, tasks/sessions/logs, komf, all server settings and import tools |
| History/statistics | Reading-history catalog, paginated admin server events, library-scoped summaries/distributions/heatmap/top authors/genres/tags; extended reading-stat endpoints with 404-only local fallback and 24-hour capability retry; offline snapshots and local progress overlay | Real extended-server acceptance, complete offline metadata indexing, all history filters/detail layouts and richer charts |
| AI/OCR | Offline ML Kit OCR for Latin/Japanese/Chinese/Korean/Devanagari on Android, WinRT OCR with installed Windows language packs, selectable text/region preview; OpenAI-compatible/OpenRouter/local provider configuration and model lists, secure API keys, strict-ID batched translations, selected EPUB text translation, translated region overlays, per-image/language cache and incognito exclusion; original Waifu2x model converted to portable ONNX with numerical source-network validation, worker-isolate inference, bounded input/output memory and disk cache | Native OCR/ONNX acceptance; learned bubble detection and exact typesetting, downloadable OCR/vision model catalog and additional recognition scripts |
| OS integrations | Android/Windows launch targets and original logo; Windows portable packaging/runtime and isolated native-startup CI probe | Widgets, search indexing, quick actions, notifications/live activities, native background work and multiple reader windows; production installers/signing |
| Artwork/localization | Original MIT logo, light/dark tokens, card dimensions, original 1,520 localization keys plus translated aliases and new Italian labels | Complete glyph/typography/animation matching; translations for new labels/errors in every language |

## Validation boundaries

The automated tests exercise the actual client against an isolated Komga 1.29.1
with synthetic CBZ, EPUB and PDF files, as well as transport, persistence, reader
state and widget layouts. The native PDF test runs on the Linux host.
EPUB tests cover nested navigation, escaped resource paths/fragments, NCX and
spine fallbacks, async chapter rendering, actual hyperlink/outline taps,
font changes without progress writes, and incognito navigation.
The default test run skips the live integration test; run it explicitly via
`tool/komga_smoke.py`. See the current run results rather than assuming a skipped
test passed.

Screenshots at mobile and desktop sizes are review artifacts. There is no
Apple-host screenshot baseline, so exact visual parity has not been verified.
The current Linux machine cannot run Windows or an accelerated Android emulator.
The API 35 GitHub runner executes a native simulated-cutout display test; it is
not physical-device gesture/performance acceptance. Windows compilation, all 96 automated tests and native window startup passed
for preview 0.5.0 on a GitHub Windows runner. See `VALIDATION.md` for the exact
source/job, startup screenshot and published artifact verification.
Device-native secure storage, accessibility,
background behavior, performance, and Windows interactions need target testing.

This is a development implementation, not a claim of a finished perfect port.

## Work in progress after 0.5.0

The changes above are not part of the published 0.5.0 APK. The development
branch passes 150 automated tests including a real Chromium EPUB layout run and actual ONNX inference,
and compiles an Android debug APK including the bundled OCR recognizers. Native WebView interaction tests have been
added to Android and Windows CI; results are still pending. The Android WebView
plugin is vendored at stable 1.1.3 with only its two ProGuard defaults updated
for AGP 9.1; original source and license are retained in `third_party/`.

Ordered read-list sync and full offline-catalog snapshot preparation also passed
the real Komga 1.29.1 acceptance test. The first new native CI run exposed the
WebView plugin's C++17/experimental-coroutine incompatibility with current MSVC;
the runner and plugin now request standard C++20. The emulator build heap and
worker count are bounded, and dependencies are compiled before the emulator
starts, after its first run lost the device connection following display tests.

The bundled Waifu2x conversion preserves all source convolutions, transposed
convolution, activations and clipping. An independent NumPy evaluation of the
source protobuf agrees with ONNX within 1.3e-6 on the conversion probes; the
Dart inference/packing test agrees with independently computed output pixels
within one byte. This does not substitute for device performance acceptance.
The optional enhancement leaves the source page visible while processing,
limits input to 2 megapixels/two requests and trims its own 256 MiB disk cache.

The Windows WebView stable plugin is also retained locally with narrow C++20
corrections (redundant member qualifiers, a missing dependent-false template,
and string mutators). See its `third_party/` patch notes. Native verification
is being rerun; the previous emulator could not allocate its data partition
after the build, so unused runner SDK images/NDKs are removed before boot.

On the API 35 emulator, the new offline ML Kit OCR and portable ONNX upscaler
passed native image tests. EPUB navigation exposed a resize/navigation race,
now reproduced and fixed in the browser regression: the host owns resizing
with numeric viewport dimensions, and waits for reflow before turning. EPUB
transitions now run inside the visible browser rather than covering the native
view during its layout work. Windows compilation is being rerun after the
WebView join accumulator and local_auth's obsolete /await flag were corrected.

The next background-download increment adds cross-connection transfer leases,
pause/resume coordination and deletion tombstones that reject late writes from
a removed account. Its OS scheduling integration remains in progress. App lock
also protects OS capture/preview surfaces while enabled and avoids repeating
a cancelled authentication prompt in the same foreground session.


Background downloads now use persisted OS scheduling with secure-vault lookups
inside the worker; job arguments contain only the data directory and account/book
identifiers. Android uses constrained per-book WorkManager jobs with bounded
8-minute runs and validated partial-file resume. Windows uses one hidden worker
per account, with Task Scheduler network/power conditions and periodic retry.
Foreground transfers obey the same metered/charging policy. Independent SQLite
connections verify lease exclusion, pause/resume, cancellation, worker timeout,
and offline/deleted-account handling. Native scheduler acceptance is added to
the Android/Windows integration target and is pending CI execution.

Current MSVC also rejects local_auth_windows 2.0.2's nonstandard `return` in a
coroutine. Its stable source/license are retained locally with `co_return` and
standard C++20 options. See `third_party/local_auth_windows/PORTING.md`.


The Windows native run for 409a791 passed real Task Scheduler worker execution,
EPUB navigation/CFI/reflow and ONNX inference. Its OCR test exposed WinRT's path
handling for Dart temporary files; bounded native reading into a memory stream
replaces StorageFile path parsing and is pending the next native run. Android
native completion is still pending; per-drive timeouts and retained logcat output
now make an emulator/service disconnection diagnosable instead of waiting for the
whole-job timeout.

The versioned document cache tests verify HTTP 304 body avoidance, immutable
refresh while a reader is open, cross-connection source leases, LRU eviction,
legacy-source migration, offline/pinned preservation and range resume without
orphan accumulation. The conditional HEAD flow also passed against real Komga
1.29.1. Cached originals are disposable; explicit downloads remain outside the
quota. Resuming online through the older direct offline property also restores
the transfer queue, fixing the live integration timeout exposed after pausing
was added. PDF detection accepts media type, profile and filename fallbacks.


Comic wide-page scrolling fills the viewport height and uses one drag owner per
gesture: an interior drag pans the spread, while a drag starting at its outer
edge turns the page. A late second finger cancels the drag before zooming.
Tests cover LTR/RTL, zoomed taps and edge routing. Cover transitions use the
existing PageView position and GPU transforms; pixel tests prove that outgoing
artwork stays stationary under the incoming page. Existing saved animation
choices migrate to slide; new reader defaults use cover as upstream does.

Immutable file GETs now retry transient connection failures up to twice, using
the validated partial journal between attempts. Authentication failures and
cancellation are not replayed. This addresses an interrupted original-file
connection exposed by the GitHub Komga acceptance run; both the fault-injection
regressions and the real Komga test pass locally.

The emulator action executes script lines in separate `/bin/sh` invocations.
The bounded native test sequence is now an explicit Bash script, preserving its
logcat process, cleanup trap and timeout configuration in one shell. Gradle
dependency and pinned NDK caches reduce repeated CI setup work.


Source 119d61a passed the complete Windows job, including native OCR,
Task Scheduler/vault worker execution, WebView2 EPUB CFI/reflow, ONNX inference,
release compilation and isolated application startup (run 40755554173).
The Android ordinary job for that source also passed real Komga acceptance and
release compilation; its native job failed in the emulator action's shell setup,
now fixed by the dedicated Bash script. Native verification of later reader
changes remains pending.

Account removal now awaits active image writes, document refreshes, page
conversions and upscaler output before deleting account files. Upscaler shutdown
also rejects work still awaiting image hashing/decoding, preventing a late worker
from being created after close. A real HTTP regression verifies image work has
settled when removal returns. The disposable GitHub NDK installation is verified
and retried on truncated SDK archives before Gradle starts.


Wide-page offsets now persist per book and reading direction, respect newer
remote reading dates, and stay unchanged during pinch cancellation or layout
restoration. LTR/RTL tests restore the same fraction through a rotation where
the whole spread fits on screen, then back to a narrower viewport, without
recording navigation. Incognito excludes the stored position.

An acknowledged unread-reset tombstone now yields to newer server progress;
unsent resets continue to win until synchronization. Window polling of SQLite's
external revision also clears memoized progress after another connection writes.
Both cases have dedicated regressions, bringing the complete local suite to
150 passing tests with Chromium and ONNX enabled (the live server test is run
separately).
