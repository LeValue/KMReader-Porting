# PDF offline: reference, adaptation and evidence

Reference: `kmworks/kmreader` at
`e2b35f8796cc830fc6e7464e161b2172d8f916e9`. This record addresses F-05's
original-file/rendering strategy. It does not close installed-device acceptance.

## Operation mapping

Upstream paths below are relative to `KMReader/`.

| Operation | Upstream source | Android/Windows port |
|---|---|---|
| Download and retain the original PDF | `Features/Offline/Services/OfflineManager.swift`: `downloadPdfFile()`, `getOfflinePDFURL()` | `Repository.download()` retains `source.pdf` in the book's download directory, outside the disposable document cache. |
| Open a downloaded PDF in the dedicated reader | `Features/Reader/ViewModels/Pdf/PdfReaderViewModel.swift`: local URL before remote acquisition | `DocumentCache.open()` leases the pinned file; `PdfReader` opens it through PDFium/pdfrx. |
| Obtain comic-reader page metadata | `Features/Reader/ViewModels/Divina/ReaderViewModel.swift`, `PdfOfflinePreparationService.loadMetadata()` | `PdfRasterReader` opens the original and exposes `PdfRasterPages.dimensions`. |
| Prepare/render comic pages | `PdfOfflinePreparationService.prepare()` and `renderPageIfNeeded()`; `ReaderPageLoadScheduler.swift` | `PdfRasterPages.page()` renders from the original on demand, coalesces duplicate requests and serializes PDFium work. |
| Retain prepared images | `PdfOfflinePreparationService.swift` writes page PNGs via `OfflineManager` and records a quality stamp | Encoded derivatives are memory-only, limited to 32 MiB and 16 entries per open `PdfRasterPages`. Closing it clears them. There is no persistent PNG set or preparation stamp to migrate or evict. |
| Clean disposable originals | Separate from a retained offline download | `DocumentCache.trim()` uses an LRU quota and active leases. Pinned downloads are in a separate directory and are retained. |

The port preserves the offline-reading operation through the downloaded original,
including pages never previously rendered. It does not implement the reference's
bulk persistent-PNG preparation. Regeneration can cost CPU/time on a cold open;
this is an implementation adaptation, not a claim of identical render latency or
energy use. PDFium and Apple PDFKit also need not render identical pixels.

## Bounds and ownership

- `PdfRasterPages` limits each raw raster to 16 million pixels, approximately
  64 MiB of RGBA data, as well as the selected long-edge limit. Encoded cache
  limits are separate from decoded Flutter images, GPU allocations and pdfrx's
  own caches; 32 MiB is not a bound on total reader memory.
- The original download remains protected from disposable document-cache cleanup.
  Active unpinned source leases also prevent eviction while a reader uses them.
  The original-cache quota and explicit removal of an offline download are
  separate policies. A cache clear does not delete reading progress.
- Passwords are requested again when needed and are not persisted. Existing
  password/error/widget tests cover both reader paths.

## Executable evidence

Run with the pinned SDK and its native PDFium hook installed by `flutter pub get`:

```sh
flutter test test/pdf_reader_test.dart test/document_cache_test.dart --reporter expanded
```

The two `persisted PDF download survives cache cleanup and SQLite/repository
restart` cases use a generated, two-page, mixed-size PDF with distinct solid
colors. They:

1. Download the original through the app repository and persist the ready status,
   offline preference and a reading position in a file-backed SQLite database.
2. Add and actually remove a disposable cached PDF, close the repository/database,
   then recreate them. Restore the offline preference as `AppController` does.
3. Open the pinned document through `DocumentCache`, then render **every page**
   using the native PDF document path or the comic `PdfRasterPages` path. Check
   decoded pixel colors, so a blank or repeated page is not a successful result.
4. Repeat with another fresh repository/database and PDF document after closing
   the first renderer. Every attempted HTTP request fails the test. Verify zero
   such requests, unchanged original bytes, ready download and retained progress.
   The book directory contains only `source.pdf`, without generated page PNGs.

Existing widget cases additionally exercise `DocumentReader` engine selection,
comic/native navigation, continuation, settings and incognito progress behavior.
Document-cache tests exercise LRU quota eviction and active-source protection.
The new restart cases test persistence and real PDFium rendering; they do not
simulate Android process death or Windows file locking with a killed process.

## Remaining acceptance

AT-02/AT-03/AT-07 remain open for installed Android and Windows: full process
termination/relaunch offline, long/large/encrypted volumes, disk pressure,
background restrictions, memory peaks, cold-page latency and measured energy.
Record renderer/source, content fixture, OS/device and results. The generated
fixture and tests require no personal server, account or copyrighted volume.
