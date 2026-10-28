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
| Comic reader | Portable raster pages and cached Komga PNG conversion for TIFF/JPEG2000 and other formats, inherited series reading direction, unified pinch/paging arbitration, idle progress/preload work, adaptive decode resolution, Android immersive display with native notch-safe controls/sheets and page bounds in either orientation, explicit cutout extension, conservative/aggressive border cropping, configurable double-tap zoom, optional cropped screen fill, paged/LTR/RTL, vertical/Webtoon, spreads, zoom, rotation, backgrounds, six upstream tap-zone presets with inversion, three preload windows, animation toggle, split wide pages in LTR/RTL/automatic order with semantic progress and half-page resume, incognito and continuation | Curl/cover animations, wide-page scrolling, device frame-time/memory acceptance |
| PDF | PDFium viewer, text search/highlights after document readiness, outline, jump/resume, auto/paged/continuous/single/dual layouts, cover-alone and RTL options, themes, password retry without persistence, original-file offline reading | Quality presets/offline raster rendering, DIVINA alternative, exact upstream gesture/animation behavior, device acceptance |
| EPUB | Native Android WebView / Windows WebView2 with bundled Epub.js, ZIP resource serving and decompression in a worker isolate; paged/scrolled reading, CFI resume and remote progression, hierarchical EPUB 2/3 contents, search/bookmarks, supplementary footnotes, columns, spacing/alignment/themes, author CSS and embedded fonts, imported TTF/OTF/WOFF fonts, IDPF/Adobe font deobfuscation, UTF-16 resources, six tap-zone presets, slide/cover/curl overlays, incognito, next-book continuation | CJK/vertical and fixed-layout edge cases, continuous cross-chapter scroll, selection/dictionary/translation tools, exact upstream typography and native gesture/performance acceptance |
| Downloads | Streaming originals and portable comic pages (including conversion/upgrade of unsupported raster formats), disk persistence, deduplicated queue with 1–3 active transfers, cancel/retry/remove, manual resume after restart, validated HTTP range/If-Range transfer resume, offline reading | Background OS jobs, network policies, archive pages on demand, disk quotas/cleanup UX, large-queue stress tests |
| Progress | Durable coalesced outbox, revision acknowledgements, retained failures, newer-remote conflict resolution | More multi-device/reconnect/device-clock stress tests; parity for every reader transition |
| Live updates | SSE subscription, debounced refresh and reconnect | Full event-specific invalidation and real SSE acceptance tests |
| Cache/performance | Persistent catalog reuse with 30-second freshness and background revalidation, request coalescing, 8 MiB hot query/32 MiB encoded-image budgets, 512 MiB temporary-image disk target and cleanup, lazy tab initialization, batched SQL writes, background EPUB indexing | Device frame-time/performance acceptance, conditional media revalidation, quotas for cached document originals, advanced preload policies |
| Settings | Theme, original ten-language catalog, dashboard sections, offline mode, downloads, server info | Some new labels/errors still need translations; full upstream preference surface |
| API keys | List/create/copy/revoke, optional automatically created and independently verified key on password login, password fallback for unsupported servers, identification/protection of the managed active key | Manual-key identity discovery, authentication/session history, target-vault acceptance |
| Administration | Library creation/editing with all creation DTO options, server-folder browser, optimistic edit checks, scan/deep scan/analyze/metadata refresh/empty trash/removal; metadata editors | Duplicate detection, tasks/sessions/logs, komf, all server settings and import tools |
| History/statistics | Reading-history catalog, paginated admin server events, library-scoped summaries/distributions/heatmap/top authors/genres/tags; extended reading-stat endpoints with 404-only local fallback and 24-hour capability retry; offline snapshots and local progress overlay | Real extended-server acceptance, complete offline metadata indexing, all history filters/detail layouts and richer charts |
| AI/OCR | Offline ML Kit OCR for Latin/Japanese/Chinese/Korean/Devanagari on Android, WinRT OCR with installed Windows language packs, selectable text/region preview, per-image/language cache and incognito exclusion | Native OCR acceptance; bubble detection/typesetting, model catalog, translation providers, upscaling |
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
branch passes 114 automated tests including a real Chromium EPUB layout run,
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
