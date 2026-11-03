# EPUB rendering audit — 0.8.13

The EPUB pipeline is a Dart resource worker, loopback publication server,
Epub.js 0.3.93 inside Android WebView/Windows WebView2, and Flutter controls.
Curl additionally snapshots the publication into SVG images and a retained
WebGL surface. The audit covers archive lifetime, browser bootstrap, initial
layout, continuous scrolling, CFI mapping, Flutter notifications, snapshot
generation, background work, GPU lifetime and failure recovery.

## Findings and changes

| Path | Critical work or retained state | Change |
|---|---|---|
| Publication resources | `ArchiveFile.content` retained every inflated chapter/image until book close, including chapters read to derive headings | Read the raw ZIP stream and retain an 8 MiB LRU working set; metadata inspection does not populate an unbounded archive cache |
| Initial document | Epub.js loaded prose into a zero-width iframe before assigning the actual viewport | Give the hidden iframe initial viewport dimensions before loading text |
| Typography | Reader styling arrived after initial publisher layout; formatting setters immediately queried computed dimensions between writes | Include typography in the serialized chapter, batch formatting writes and measure the final geometry through the existing expand path |
| Vertical scrolling | Every manager check called `show()` again, toggling `translateZ` and reading `offsetWidth` on already visible iframes | Run that first-show/redraw path only when the view becomes visible |
| Chapter lifetime | Removing an iframe retained its source DOM/XHTML on the spine and its render promise on reusable continuous views | Unload unused section sources and clear the removed view's render promise; revisiting reloads the chapter |
| Flutter controls | Input events and unchanged browser reports notified the whole reader | Notify session listeners only when displayed state changes |
| Browser bootstrap | The browser loaded JSZip although Dart already serves uncompressed resources | Remove the unused browser ZIP script and worker asset copy |
| Curl snapshots | Every page raster laid out all prose glyphs in the chapter | Replace eligible offscreen prose with measured flow boxes in the temporary SVG only; retain fragmented paragraphs, complex layout and relational-selector documents |
| Snapshot validity | Cached prose geometry could outlive content changes | Invalidate captures on content mutations/reflow and disconnect document observers on destruction |
| Speculative work | An idle callback could continue preparing another page after input/preferences had changed | Retire jobs by generation and publication revision; do not force idle work onto a busy browser with an expiry timeout |
| GPU lifetime | Switching from curl to vertical/direct/slide retained graphics and embedded-resource caches | Dispose the unused curl context and release decoded-page, markup and resource caches; release failed effects' retained caches too |
| Motion failures | Draw errors, lost contexts or stalled preparations could retain an opaque overlay | Bounded preparation, cancellation/watchdog cleanup and direct reading after GPU failure |
| Native reopening | A saved CFI could be valid while its iframe height was zero | Detect the invalid native view, reframe and restore the same locator |
| Delayed frames | Capped deltas stretched motion; using the request clock could consume playback before a delayed first frame | Anchor to the first delivered RAF timestamp, then use actual elapsed frame time |

The existing retained CFI mapper remains differential-tested against the stock
mapper. Actual font, viewport, resource and content changes still invalidate
geometry. Fixed-layout and CJK publications retain their separate paths.

## Evidence

The [reproducible pipeline benchmark](benchmarks/epub-pipeline-0.8.13.json)
compares 0.8.12 with the candidate using generated long prose, CPU throttling 6,
and identical headless Chromium/viewport. These are one sequential pair of
browser samples, not universal device performance or native display FPS.

| Measurement | 0.8.12 | Candidate |
|---|---:|---:|
| Paged opening, direct motion | 3299 ms | 1706 ms |
| First cold curl preparation | 2570 ms | 1840 ms |
| Following curl preparation, median of 4 inputs | 1041 ms | 252 ms |
| Vertical opening | 2731 ms | 1400 ms |
| Vertical scroll browser task work | 366 ms | 214 ms |
| Layouts during the same 40-step vertical scroll | 78 | 0 |

The first cold curl remains the most expensive sampled interaction because it
includes graphics initialization. The benchmark exposes it separately; it is
not hidden in discarded warm-up samples. Physical release timings remain a
separate measurement.

`tool/epub_snapshot_smoke.py` compares full and compact page rasters at four
chapter positions, phone/desktop widths and LTR/RTL. All visible pixels must
match within a 4-channel-value antialiasing tolerance. Fragmentation is covered:
replacing a split paragraph's line boxes or losing widow/orphan constraints
caused an earlier version of this optimization to fail this test. Those
paragraphs now retain their original text and line boxes.
An additional regression makes authored `nowrap` text overflow from the
preceding page. It must remain pixel-identical too. Overflow, shadows, generated
content and complex authored boxes retain the full snapshot path; nearby line
boxes are preserved for glyph overhangs.

The resource-cache regression requires repeated small reads to reuse bytes,
evicts resources beyond the working budget, reloads them correctly and revisits
publication text. The mapper checks that discarded source documents are gone,
revisiting still works, repeated continuous-manager checks perform no iframe
restyling, CFIs match upstream, and all geometry observers are released.

Native graphics recovery and its physical-test limits are recorded in
[Android recovery validation](ANDROID_EPUB_RECOVERY.md). Final Android/Windows
packages must come from the checked source with native CI passing. The
downloaded Alice EPUB and process-wide physical memory/FPS are not measured by
the generated-fixture browser benchmark.
