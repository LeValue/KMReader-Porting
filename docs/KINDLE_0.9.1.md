# Kindle corrections in 0.9.1

The pinned download queue could not inspect an EPUB because an isolate closure
captured the queue's `Completer`. Top-level compute callbacks now receive plain
values. A regression test uses `Repository.download`, including progress,
cancellation and the actual queue, rather than testing only the document cache.

Prepared books are reused between reader opens and pinned downloads. Windows
reuses an on-demand JSON-lines converter process instead of starting two nested
executables for every conversion. Deferred annotation packages no longer block
content downloads: annotations have their own sidecar read path. The download
queue also skips the optional cover prefetch before starting the book transfer.
First acquisition of a KFX still needs complete content and conversion to EPUB;
this release does not claim the official Kindle app's 2–3 second latency.

Covers and available page metadata can be read before downloading the book.
The app signs bounded Range requests through a capability protected loopback
bridge; the worker receives no account token, key or cookie. Covers and metadata
are cached. A real GET-only desktop check retrieved a personal document's cover
using 1,048,576 of 3,205,413 resource bytes, in 6.92 seconds including manifest
latency. This is a cold metadata measurement, not a full-download benchmark.

The dashboard's `createdDate` and `lastModifiedDate` sorts use the equivalent
stored catalog dates. Bundled Amazon dictionaries are always excluded and their
settings toggle is removed. Kindle services are managed inside Settings and
Servers: refresh, position sync, annotation import, automatic catalog refresh,
cover retrieval, reconnect and preparation cache cleanup. The desktop account
button opens Servers directly.

The reader counter describes the complete volume. When no publisher count is
available, it uses stable logical pages of 1,024 Unicode scalars, marked `~`.
A background/cache index weights chapters by their actual text length. It does
not paginate all chapters in the WebView. Tapping the counter opens a compact
volume slider, page entry, chapter shortcuts, contents and bookmarks. Unknown
catalog counts are not displayed as zero; native PDF preparation supplies its
actual page count.

Original Kindle positions are indexed by an interval tree. Matching-edition
bookmarks, highlights and notes are imported into the existing bookmarks UI.
Highlights use an SVG overlay and do not replace publication text nodes. Remote
snapshots can remove cloud annotations without deleting local bookmarks.
Position writes retain the existing edition, conflict, outbox and read-back
checks. **Annotation import is one-way**: local bookmarks are not represented as
successfully uploaded to Amazon. The write protocol for annotations has not
been verified on the personal account.

Windows opens normal Chrome without a replacement profile or debugging flags.
The user completes login/OTP and explicitly pastes the final address into
KMReader. It is consumed privately and never displayed in diagnostics. Automatic
capture in a separate browser remains an optional compatibility setting.

Validation includes the complete Flutter and Python suites, real Chromium
reader checks, native Windows/Android CI, packaged worker self-checks and an
opt-in GET-only app-runtime probe on the user's personal Windows runner.
The runtime probe rejects annotation writes before sending a request, keeps
credentials/books in temporary private storage and uploads only metrics.
