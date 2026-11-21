# Documentation

Public preview: **1.0.0 candidate 15, build 45** for Android and Windows.
[Download](https://github.com/LeValue/KMReader-Porting/releases/tag/v1.0.0-candidate.15)
· [Release notes](releases/v1.0.0.md) · [Report an issue](https://github.com/LeValue/KMReader-Porting/issues)

Stable 1.0 and full upstream parity are still in progress. Most general guides
are in English; the detailed Komga administration and Kindle document-management
guides and porting checklist are currently in Italian.

## Using the app

| Task | Guide |
|---|---|
| Install, connect accounts, import local files and update | [Getting started](GETTING_STARTED.md) |
| Upload to a Komga server, edit metadata/covers or delete volumes | [Komga library management and Debian setup (Italian)](KOMGA_LIBRARY_MANAGEMENT.md) |
| Send local documents to the Kindle cloud or selected devices | [Send to Kindle](KINDLE_IMPORT.md) |
| Edit/delete personal Kindle documents and preserve reading state | [Kindle document management (Italian)](KINDLE_LIBRARY_MANAGEMENT.md) |
| Understand supported features and remaining work | [Roadmap](ROADMAP_1.0.md), [porting checklist (Italian)](PARITY.md) |

## Developing and contributing

| Task | Guide |
|---|---|
| Report a problem or contribute a change | [Contributing](../CONTRIBUTING.md) |
| Set up the pinned SDK and run the app | [Development](DEVELOPMENT.md) |
| Run host, browser, backend and native tests | [Testing](TESTING.md) |
| Understand shared Python app dependencies | [Kindle runtime](KINDLE_RUNTIME.md), [tool index](../tool/README.md) |
| Build, sign and publish packages (maintainers) | [Releasing](RELEASING.md) |
| Use interactive self-hosted diagnostics (maintainers) | [Windows diagnostics](LOCAL_WINDOWS_TESTS.md), [Android recovery](ANDROID_EPUB_RECOVERY.md) |

## Technical reference and historical evidence

| Area | Records |
|---|---|
| Release checks and known validation limits | [Validation history](VALIDATION.md) |
| Cover actions, upstream mapping and verification | [Cover parity](COVER_PARITY.md) |
| PDF offline strategy, cache ownership and restart evidence | [PDF offline parity](PDF_OFFLINE_PARITY.md) |
| Current code review and Android battery measurements | [Code audit](CODE_AUDIT.md), [battery profiling](BATTERY_PROFILING.md) |
| Reader rendering and performance | [Performance](PERFORMANCE.md), [EPUB audit](EPUB_RENDERING_AUDIT.md), [comic curl](COMIC_CURL_RENDERING.md) |
| Upstream scope and platform adaptations | [Settings audit](SETTINGS_AUDIT.md), [iPad reference](IPAD_REFERENCE.md) |
| Asset reproduction | [Bubble model](BUBBLE_MODEL.md) |
| Versioned changes | [Release notes](releases/) and [0.9.1 Kindle corrections](KINDLE_0.9.1.md) |
| Repository organization and retained history | [Repository audit](REPOSITORY_AUDIT.md), [inventory](inventory/repository-before-2026-11-07.json) |
| Superseded experiments | [Archive](../archive/README.md) |

Measurements apply to the source, hardware and commands named in each record;
they are not guarantees for every device or the current checkout. Historical
records may link to CI artifacts that expire or old release drafts that are
visible only to maintainers. Use the public download above for installation.
