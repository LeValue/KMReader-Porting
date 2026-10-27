# 0.2.0 performance and porting changes

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
