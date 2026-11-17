# Code review: correctness, responsiveness and energy

This review follows public candidate 6 (build 36), source `b8ca029` before these
changes. The fixes below are development changes on `main`; the existing public
build 36 packages do not acquire them through documentation or source updates.

## Scope and evidence

The review combines static analysis of the Dart application, searches across the
142 application source files, native power integration and shipped EPUB scripts,
inspection of critical lifecycle/network/cache paths, and host regression tests.
It is not a physical-device energy/FPS benchmark, a security certification, or a
claim that every line and upstream operation has been independently verified.

Final host validation passed 459 tests with 43 explicit skips; the focused suite
passed 35 checks and the Python tool suite passed 26. Static analysis and
whole-tree formatting passed. Native/device acceptance is recorded separately.

No real Amazon account or personal server was used. No authorized Android device
was connected to the execution environment. Existing device evidence remains
versioned in [validation](VALIDATION.md).

## Confirmed defects and changes

| Finding | Consequence | Change and verification |
|---|---|---|
| Download coordinator polls SQLite every second, including empty queues and hidden app | Avoidable periodic wakeups and platform calls | Stop periodic foreground observation when hidden/paused/detached; use 15 seconds while idle and retain 1 second for tracked OS downloads. Refresh immediately on resume. Lifecycle regression advances fake time for two background minutes and checks that probing stops. |
| Background-disabled policy cancels OS jobs but does not prevent an existing foreground transfer from continuing after the app is hidden | Background traffic can violate the user's preference | Apply the policy to foreground transfer admission and pause/resume as lifecycle changes. Test disabled and enabled background policies separately. Explicitly allowed background work remains supported. |
| Live Komga subscription/reconnect timer has no application visibility gate | Hidden app can retain catalog traffic and reconnect repeatedly | Cancel the subscription and reconnect/refresh timers while hidden; preserve the last event ID and invalidate foreground content on return when automatic refresh is enabled. Tests check cancellation, reconnect ID, idempotent resume and disabled auto-refresh. Cached covers are conditionally revalidated on resume, retaining cached bytes. Kindle's separate refresh settings are preserved. |
| Komf polling continues while application is hidden | Two-second job checks even when UI is unavailable | Suspend tracking timer and HTTP polling in background; resume existing jobs on return without reissuing the server job. Regression checks that background polling issues no HTTP request. |
| Waiting for response headers can time out without aborting the HTTP request | An apparently completed failure can leave network work alive | Give each request an internal abort trigger and complete it on timeout, also retaining caller cancellation. A stalled-request regression observes the actual abort. Mutation retry rules remain unchanged. |

Idle coordinator observations change from 60 to 4 per minute; its periodic
background observations change to zero. These are scheduler counts, **not** a
measured percentage of battery saved. Connectivity/power events and explicitly
allowed transfers can still perform work.

## Subsystem review and outstanding work

| Area and sources | Observations | Further acceptance / investigation |
|---|---|---|
| Networking: `api.dart`, `server_event.dart`, `repository.dart` | Same-origin paths, disabled credential redirects, safe-read retries and explicit mutation handling; new header-timeout cancellation and lifecycle gates | Profile response-body timeouts/cancellation and slow-server scenarios on native HTTP clients. Confirm reconnect reconciliation with a real server and app suspension. |
| Downloads: `background_downloads.dart`, `download_worker.dart`, `document_cache.dart` | Durable work, leases, bounded concurrency, power/network policies and resumable original files; polling fixed above | Exercise process death, long downloads and OS background restrictions on hardware. Active-transfer heartbeats remain intentional. |
| Kindle: `kindle/repository.dart`, `kindle/worker.dart` | Progress debounce, conversion worker queue and idle shutdown exist; document mutations have separate recovery records | Measure conversion CPU, initial catalog/cover work and long-book preparation. Do not suspend a pending reading-position write blindly or infer Amazon acceptance from mocks. F-13 remains open. |
| EPUB: `assets/epub/reader.js`, `epub_session.dart`, `epub_document.dart` | Motion preparation has eligibility checks, hidden-page cancellation, bounded warm textures and resource caches; saves are debounced; upscaler inference uses a dedicated isolate | Physical Hyperion forward/backward and chapter-boundary acceptance remains open. Capture preparation/render frame traces before changing texture quality or warmup policy. |
| Comics: `comic_frames.dart`, `reader_page.dart`, `page_transition.dart` | Frame cache is bounded; page readiness waits are bounded; image work is separated from reader state | Measure allocation spikes on large spreads and actual touch/tap frame pacing. A bounded wait is not proof of smooth rendering on a particular GPU. |
| PDF: `pdf_reader.dart`, `document_cache.dart` | Original documents are retained and derived resources have separate policies | F-05 still requires restart-offline and derivative-quota acceptance for both reader paths. |
| Display power: `reader_display.dart`, Android `MainActivity.kt`, Windows `flutter_window.cpp` | Keep-awake ownership is tied to reader visibility/lifecycle and the native integration uses screen-awake flags, not an app-wide Android partial wake lock | Screen brightness and a deliberately enabled keep-awake setting may dominate reading consumption. Verify route transitions and backgrounding on the affected phone. |
| Catalog, persistence and metadata: `store.dart`, `offline_catalog.dart`, `catalog_tools.dart` | Account scopes, query invalidation and external SQLite revision handling are present; image-cache trimming is already debounced and limited to once per minute | Finish A-01/A-02 field/action inventory and F-01/F-02/F-09 on controlled equivalent data, including extended endpoints. |
| Administration: `komga_library_admin.dart`, `tool/komga_admin` | Upload, metadata, cover change and confirmed deletion have dedicated tests | The follow-up implements selection/removal/restoration and manual refresh; see [cover parity](COVER_PARITY.md). Installed-device and extension-server acceptance remain open. |
| Settings, localization and accessibility | Existing settings audit distinguishes supported, adapted, partial and unavailable options | F-11/F-12 and AT-08 remain open. Do not label an English fallback as a completed translation. |
| Packaging and privacy | Runtime paths, existing public signing identity and source-bound delivery remain intact | A new binary requires a higher build number and full release/native checks. Keep profiling captures private and publish only sanitized aggregates. |

## Follow-up fixes

The previous lifecycle changes passed all native/source CI jobs in
[run 44090954246](https://github.com/LeValue/KMReader-Porting/actions/runs/44090954246).
A subsequent source change extends HTTP cancellation to JSON/image response-body
consumption and uploads. Error response bodies are canceled rather than consumed
without a bound; a real loopback socket test verifies disconnection on timeout.
Read retries remain bounded, while mutation requests are not replayed.

Cover-version management, original artwork restoration and explicit list/volume
cover refresh now have [documented paths and backend evidence](COVER_PARITY.md).
Komga upload progress repainting is limited to roughly 10 updates/second plus
completion; this is a bound on UI updates, not a physical FPS/energy measurement.

The fixes above and update recovery are distributed in [candidate 7/build 37](https://github.com/LeValue/KMReader-Porting/releases/tag/v1.0.0-candidate.7)
at source `9b03716a6204a8696b861531791150e48e5b5eef`; [full source CI](https://github.com/LeValue/KMReader-Porting/actions/runs/44108656435) passed.
This does not establish physical-device battery savings or reader acceptance.

## Next priorities

1. Run the controlled [battery protocol](BATTERY_PROFILING.md) on the affected
   Android device; compare identical conditions and distinguish idle, reading,
   sync and conversion. Fix demonstrated hotspots before adding quality tradeoffs.
2. Validate the completed [cover flows](COVER_PARITY.md) on installed clients and
   a real smart-list extension server; continue the broader upstream action/field
   inventory (A-01/A-02).
3. Capture native reader traces for the reported slide/curl transitions (AT-07),
   including cold/warm pages, both directions and chapter boundaries.
4. Continue offline PDF/cache and localization acceptance with controlled fixtures.

[Porting closure matrix](PARITY.md) records the separate requirements; these
changes do not declare stable 1.0 ready.
