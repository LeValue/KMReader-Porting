# Functional and visual parity

Reference: kmworks/kmreader `e2b35f8796cc830fc6e7464e161b2172d8f916e9`.
This matrix distinguishes implemented behavior from full upstream parity.

| Area | Implemented | Remaining work |
| --- | --- | --- |
| Authentication | Password, API key, first-server claim, account-scoped profiles, OS credential vault | Device biometrics/Windows Hello; device-level vault validation |
| Server management | Add, reconnect, switch, remove; isolated caches/files/outbox | More server editing and protection options |
| Dashboard | Keep Reading, On Deck, new books/series, updated series; hide sections | Reordering, all card styles, library scopes, read-list continuation section |
| Catalog | Paginated series/books, submitted search, library browser, sort and read-status filters | Advanced metadata filters, saved filters, batch selection and actions |
| Details and lists | Covers, metadata/summary, read/unread, collections/read lists, adding entries and creating lists from entries | Metadata editor, list editing/pinning/reordering, smart lists |
| Comic reader | Paged/LTR/RTL, vertical/Webtoon, spreads, zoom, rotation, tap zones, keyboard, resume, incognito, next book/list continuation | Curl/cover animations, border cropping, splitting wide pages, configurable tap presets, preload profiles |
| PDF | PDFium viewer, text search/highlights, outline, jump/resume, original-file offline reading | All presentation/spread/quality modes, DIVINA alternative, encrypted-document UX |
| EPUB | ZIP/OPF spine, scrolling HTML, hierarchical EPUB 3 nav/EPUB 2 NCX with spine fallback, chapter/section hyperlinks, text size/font/theme, position-preserving text changes, local position, canonical remote progression | Paged/curl/cover, columns, embedded fonts, navigation to non-spine resources, exact CSS/layout parity, robust image-layout restoration |
| Downloads | Streaming source files, comic pages, disk persistence, retry/cancel/remove, offline reading | Background OS jobs, per-series/list policies, queue limits, archive pages on demand, cache quotas/cleanup UX |
| Progress | Durable coalesced outbox, revision acknowledgements, retained failures, newer-remote conflict resolution | More multi-device/reconnect/device-clock stress tests; parity for every reader transition |
| Live updates | SSE subscription, debounced refresh and reconnect | Full event-specific invalidation and real SSE acceptance tests |
| Settings | Theme, original ten-language catalog, dashboard sections, offline mode, downloads, server info | Some new labels/errors still need translations; full upstream preference surface |
| API keys | List, create/copy and revoke | Active-key indication and automatic key creation on password login |
| Administration | Queue library scan, analyze and metadata refresh | Library creation/editing, metadata editor, duplicate detection, logs, sessions/tasks, komf |
| History/statistics | Current per-book progress | Reading history, heatmap, streaks and server/local statistics |
| AI/OCR | Not implemented | Cross-platform OCR, bubble detection/typesetting, model catalog, translation providers, upscaling |
| OS integrations | Android/Windows launch targets and original logo | Widgets, search indexing, quick actions, notifications/live activities, native background work and multiple reader windows |
| Artwork/localization | Original MIT logo, light/dark color tokens, card dimensions, 1,520 original localization keys | Complete glyph/typography/animation matching and translated new messages |

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
emulator. Windows CI is checked in but remains unrun until the code is pushed
to a repository with Actions enabled. Device-native secure storage, accessibility,
background behavior, performance, and Windows interactions need target testing.

This is a development implementation, not a claim of a finished perfect port.
