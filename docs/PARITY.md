# Functional and visual parity

Reference: kmworks/kmreader `e2b35f8796cc830fc6e7464e161b2172d8f916e9`.
This matrix distinguishes implemented behavior from full upstream parity.

| Area | Implemented | Remaining work |
| --- | --- | --- |
| Authentication | Password, API key, first-server claim, account-scoped profiles, OS credential vault, self-service password changes with Basic credential replacement/reconnect and API-key preservation; optional device biometrics/PIN/Windows Hello app lock with cold-start and background protection | Device-level vault and OS authentication acceptance |
| Server management | Add, reconnect, switch, remove; isolated caches/files/outbox | More server editing and protection options |
| Dashboard | Keep Reading, On Deck, new books/series, updated series, recently read and recently released books; hide/reorder sections, persistent library scope, matching See All filters/sort, opt-in ordered read-list continuation with upstream-compatible client-settings sync and durable stop tombstones, compact empty sections, persistent large/medium/small/horizontal card styles | Native acceptance for read-list continuation |
| Catalog | Paginated series/books, submitted search, library browser, sort/read-status and nested typed metadata filters, per-account saved filters, selection of loaded items or all matching paginated results, batch read/unread/download/list actions; account-scoped SQLite FTS metadata index with full snapshot preparation, Unicode search, nested filters, sorts and local progress | Every upstream card/sort/filter presentation; offline special-list and On Deck parity |
| Details and lists | Covers, metadata/summary, read/unread, collections/read lists; metadata editing with field locks and explicit batch changes; nonempty list creation, membership editing/reordering/deletion, personal pins; kmrs server smart-list CRUD, visibility and admin sharing, preserving uneditable conditions | Custom thumbnails, all detail layouts, real kmrs smart-list/sharing acceptance tests |
| Comic reader | Portable raster pages and cached Komga PNG conversion for TIFF/JPEG2000 and other formats, inherited series reading direction, unified pinch/paging arbitration, idle progress/preload work, adaptive decode resolution, Android immersive display with native notch-safe controls/sheets and page bounds in either orientation, explicit cutout extension, conservative/aggressive border cropping, configurable double-tap zoom, optional cropped screen fill, paged/LTR/RTL, vertical/Webtoon, spreads, zoom, rotation, backgrounds, six upstream tap-zone presets with inversion, three preload windows, animation toggle, optional automatic original-model Waifu2x upscaling, split wide pages in LTR/RTL/automatic order with semantic progress and half-page resume, height-fitted wide-page panning with saved pan positions, rotation restoration and gesture ownership/edge turns, GPU cover/slide transitions, incognito and continuation | Curl animation, device frame-time/memory acceptance |
| PDF | PDFium viewer, text search/highlights after document readiness, outline, jump/resume, auto/paged/continuous/single/dual layouts, cover-alone and RTL options, themes, password retry without persistence, original-file offline reading | Quality presets/offline raster rendering, DIVINA alternative, exact upstream gesture/animation behavior, device acceptance |
| EPUB | Native Android WebView / Windows WebView2 with bundled Epub.js, ZIP resource serving and decompression in a worker isolate; paged/continuous cross-chapter scrolled reading with bounded viewport preloading, CFI resume and remote progression, hierarchical EPUB 2/3 contents, search/bookmarks, supplementary footnotes, columns, spacing/alignment/themes, author CSS and embedded fonts, imported TTF/OTF/WOFF fonts, IDPF/Adobe font deobfuscation, UTF-16 resources, six tap-zone presets, slide/cover/curl overlays, incognito, next-book continuation | CJK/vertical and fixed-layout edge cases, dictionary tools, exact upstream typography and native gesture/performance acceptance |
| Downloads | Streaming originals and portable comic pages (including conversion/upgrade of unsupported raster formats), disk persistence, deduplicated queue with 1–3 active transfers, cancel/retry/remove, automatic resume after restart, validated HTTP range/If-Range transfer resume, cross-process SQLite transfer leases, account-deletion tombstones, Android WorkManager / hidden Windows Task Scheduler workers, unmetered/charging rules, offline reading | OEM scheduling acceptance, archive pages on demand, disk quotas/cleanup UX, large-queue stress tests |
| Progress | Durable coalesced outbox, revision acknowledgements, retained failures, newer-remote conflict resolution | More multi-device/reconnect/device-clock stress tests; parity for every reader transition |
| Live updates | Complete multiline UTF-8 SSE events, Last-Event-ID reconnect, targeted thumbnail generations and path subscriptions, independent persisted task-queue updates, debounced content refresh | More event-specific metadata invalidation |
| Cache/performance | Persistent catalog reuse with 30-second freshness and background revalidation, request coalescing, 8 MiB hot query/32 MiB encoded-image budgets, 512 MiB temporary-image disk target and cleanup, instant stale-media display with conditional GET revalidation, persisted image generations and cross-process write leases, versioned EPUB/PDF source cache with conditional HEAD revalidation and configurable 128 MiB–8 GiB quota (1 GiB default), protection of active and downloaded originals, lazy tab initialization, batched SQL writes, background EPUB indexing | Device frame-time/performance acceptance, advanced preload policies |
| Settings | Theme, original ten-language catalog, dashboard sections, offline mode, downloads, server info | Some new labels/errors still need translations; full upstream preference surface |
| API keys | List/create/copy/revoke, optional automatically created and independently verified key on password login, password fallback for unsupported servers, identification/protection of the managed active key | Manual-key identity discovery, authentication/session history, target-vault acceptance |
| Administration | Library creation/editing with all creation DTO options, server-folder browser, optimistic edit checks, scan/deep scan/analyze/metadata refresh/empty trash/removal; metadata editors; duplicate-file catalog; live task queue and execution metrics (extended-server/Actuator fallback), scheduled tasks, session listing/revocation with per-user Komga fallback, shutdown, bounded log viewer and native file export; optional kmrs Komf search/identify/match/reset, provider links and own-job tracking with metadata refresh | Connected Komf backend acceptance, all server settings and import tools |
| History/statistics | Reading-history catalog, paginated admin server events, library-scoped summaries/distributions/heatmap/top authors/genres/tags; extended reading-stat endpoints with 404-only local fallback and 24-hour capability retry; offline snapshots and local progress overlay | Real extended-server acceptance, complete offline metadata indexing, all history filters/detail layouts and richer charts |
| AI/OCR | Offline ML Kit OCR for Latin/Japanese/Chinese/Korean/Devanagari on Android, WinRT OCR with installed Windows language packs, selectable text/region preview; OpenAI-compatible/OpenRouter/local provider configuration and model lists, secure API keys, strict-ID batched translations, selected EPUB text translation, translated region overlays, per-image/language cache and incognito exclusion; original Waifu2x model converted to portable ONNX with numerical source-network validation, worker-isolate inference, bounded input/output memory and disk cache | Learned bubble detection and exact typesetting, downloadable OCR/vision model catalog and additional recognition scripts |
| OS integrations | Android/Windows launch targets and original logo; Windows portable packaging/runtime and isolated native-startup CI probe | Widgets, search indexing, quick actions, notifications/live activities, multiple reader windows; production installers/signing |
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

## Development after 0.5.0 (unpublished)

Source `81c3a1dcef7f322358b42af03314738da4f5d82a` passed all three build/test jobs
in [workflow 40789619987](https://github.com/LeValue/KMReader-Porting/actions/runs/40789619987):
Android release, API 35 native integration, and Windows native integration/release/startup.
The native checks execute real WorkManager/Task Scheduler workers with vault
credential lookup and HTTP transfers, WebView/WebView2 EPUB navigation/CFI/reflow,
OCR, ONNX inference, and OS display-awake request/release. Android also checks
simulated notch geometry/rotation and captures the composed EPUB via PixelCopy.
These are controlled native fixtures, not physical-device performance measurements.

The development suite passes 200 automated tests and covers actual Chromium EPUB rendering and ONNX inference,
progress conflicts between SQLite connections, multi-worker media generations,
conditional HTTP 304 validation, immutable document refresh, download pause/resume,
account deletion with active writes, wide-page gesture ownership and pan restoration.
Server-management tests additionally cover permissions, optional capabilities,
per-user session fallback, offline snapshots, bounded uncached logs and streaming
export, plus 320/1280-pixel layouts with enlarged text. Read-only management and
duplicate-file listing also pass against isolated Komga 1.29.1; destructive actions
use isolated transport fixtures.

Active/downloaded documents are protected from the temporary document quota.
Background jobs receive only account/book identifiers and private directory paths;
credentials are loaded from the OS vault in the worker. Logs are not cached in
SQLite. Explicit log exports stream to a private temporary file, use Android SAF
or the Windows Save dialog, and remove temporary files afterwards.

Stable WebView and Windows authentication plugins are vendored with their original
licenses and narrow AGP/C++20 compatibility patches documented in `third_party/`.
The original Waifu2x weights are converted to portable ONNX; independent source
network probes agree within 1.3e-6 and output packing within one byte. Enhancement
runs in a worker isolate with bounded tiles/memory while original artwork stays visible.

The current published release is still 0.5.0. Development changes require a new
versioned, signed release and download verification before delivery. The remaining
functional gaps are listed above; exact visual parity has no Apple-host baseline.

Komf capability probing is account-scoped, coalesced and caches only HTTP 404
for 24 hours. Pending connections are checked again on the next visit. Provider
search ignores superseded responses; oneshots can use book-level provider links.
Job polling never overlaps, pauses offline and stops with the repository on a
server switch. Timeout or repeated errors report tracking stopped without
claiming that the server job failed. Controlled tests cover these flows and
320/1280-pixel layouts. Stock Komga 1.29.1 acceptance verifies unsupported fallback;
a connected kmrs/Komf instance has not been available for live acceptance.

EPUB scrolled mode now uses the continuous manager, preloads around the viewport
and preserves CFI through flow changes and cold starts. Disabling browser scroll
anchoring prevents double compensation when Epub.js prepends the previous chapter.
Scroll intent survives delayed chapter insertion; repeated identical relocations
do not create progress writes. Manager replacement removes its publication hooks,
queues, timers and listeners. Real Chromium acceptance covers crossing both ways,
repeated flow switches, font reflow without progress, second-chapter cold resume,
backward scrolling after resume, and teardown. Native CI additionally switches
flow in the actual WebView settings and navigates after restoring paged mode.

Account password changes now use the self-service v2 endpoint, replace only
Basic credentials in the OS vault, and reconnect the same account. API-key
authentication remains independent. Lost-response verification avoids replaying
the password mutation, and removal/server-switch races cannot retarget another
account or restore deleted credentials. Secure-store failure explicitly requires
sign-in; passwords never enter SQLite. Tests cover those cases plus pending form
navigation and confirmation at 320/1280 pixels. Disposable real Komga acceptance
changes the fixture password, verifies authentication, restores it, and verifies
authentication again. Successful re-login also clears a previous offline flag.
