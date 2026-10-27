# Functional and visual parity

Reference: kmworks/kmreader `e2b35f8796cc830fc6e7464e161b2172d8f916e9`.
This matrix distinguishes implemented behavior from full upstream parity.

| Area | Implemented | Remaining work |
| --- | --- | --- |
| Authentication | Password, API key, first-server claim, account-scoped profiles, OS credential vault | Device biometrics/Windows Hello; device-level vault validation |
| Server management | Add, reconnect, switch, remove; isolated caches/files/outbox | More server editing and protection options |
| Dashboard | Keep Reading, On Deck, new books/series, updated series; hide/reorder sections, persistent library scope, matching See All filters/sort, compact empty sections | All card styles, read-list continuation section |
| Catalog | Paginated series/books, submitted search, library browser, sort/read-status and nested typed metadata filters, per-account saved filters, selection of loaded items, batch read/unread/download/list actions | Full offline metadata index/search, server-wide selection, every upstream card/sort/filter presentation |
| Details and lists | Covers, metadata/summary, read/unread, collections/read lists; metadata editing with field locks and explicit batch changes; nonempty list creation, membership editing/reordering/deletion, personal pins; kmrs server smart-list CRUD, visibility and admin sharing, preserving uneditable conditions | Custom thumbnails, all detail layouts, real kmrs smart-list/sharing acceptance tests |
| Comic reader | Portable raster pages and cached Komga PNG conversion for TIFF/JPEG2000 and other formats, inherited series reading direction, paged/LTR/RTL, vertical/Webtoon, spreads, zoom, rotation, backgrounds, six upstream tap-zone presets with inversion, three preload windows, animation toggle, split wide pages in LTR/RTL/automatic order with semantic progress and half-page resume, incognito and continuation | Curl/cover animations, border cropping, wide-page scrolling, device frame-time/memory acceptance |
| PDF | PDFium viewer, text search/highlights after document readiness, outline, jump/resume, auto/paged/continuous/single/dual layouts, cover-alone and RTL options, themes, password retry without persistence, original-file offline reading | Quality presets/offline raster rendering, DIVINA alternative, exact upstream gesture/animation behavior, device acceptance |
| EPUB | ZIP/OPF spine, scrolling HTML, hierarchical EPUB 3 nav/EPUB 2 NCX with spine fallback, chapter/section hyperlinks and non-spine footnotes with a return to the canonical reading position, text size/font/theme, position-preserving text changes, local position, canonical remote progression | Paged/curl/cover, columns, embedded fonts, exact CSS/layout parity, robust image-layout restoration |
| Downloads | Streaming originals and portable comic pages (including conversion/upgrade of unsupported raster formats), disk persistence, deduplicated queue with 1–3 active transfers, cancel/retry/remove, manual resume after restart, validated HTTP range/If-Range transfer resume, offline reading | Background OS jobs, network policies, archive pages on demand, disk quotas/cleanup UX, large-queue stress tests |
| Progress | Durable coalesced outbox, revision acknowledgements, retained failures, newer-remote conflict resolution | More multi-device/reconnect/device-clock stress tests; parity for every reader transition |
| Live updates | SSE subscription, debounced refresh and reconnect | Full event-specific invalidation and real SSE acceptance tests |
| Cache/performance | Persistent catalog reuse with 30-second freshness and background revalidation, request coalescing, 8 MiB hot query/32 MiB encoded-image budgets, 512 MiB temporary-image disk target and cleanup, lazy tab initialization, batched SQL writes, background EPUB indexing | Device frame-time/performance acceptance, conditional media revalidation, quotas for cached document originals, advanced preload policies |
| Settings | Theme, original ten-language catalog, dashboard sections, offline mode, downloads, server info | Some new labels/errors still need translations; full upstream preference surface |
| API keys | List/create/copy/revoke, optional automatically created and independently verified key on password login, password fallback for unsupported servers, identification/protection of the managed active key | Manual-key identity discovery, authentication/session history, target-vault acceptance |
| Administration | Library creation/editing with all creation DTO options, server-folder browser, optimistic edit checks, scan/deep scan/analyze/metadata refresh/empty trash/removal; metadata editors | Duplicate detection, tasks/sessions/logs, komf, all server settings and import tools |
| History/statistics | Reading-history catalog, paginated admin server events, library-scoped summaries/distributions/heatmap/top authors/genres/tags; extended reading-stat endpoints with 404-only local fallback and 24-hour capability retry; offline snapshots and local progress overlay | Real extended-server acceptance, complete offline metadata indexing, all history filters/detail layouts and richer charts |
| AI/OCR | Not implemented | Cross-platform OCR, bubble detection/typesetting, model catalog, translation providers, upscaling |
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
The current Linux machine cannot run a Windows build or an accelerated Android
emulator. Windows compilation, all 85 automated tests and native window startup passed
for preview 0.4.0 on a GitHub Windows runner. See `VALIDATION.md` for the exact
source/job, startup screenshot and published artifact verification.
Device-native secure storage, accessibility,
background behavior, performance, and Windows interactions need target testing.

This is a development implementation, not a claim of a finished perfect port.
