# Documentation

Current source: **1.0.0+36 development candidate**, based on working 0.9.1.
Latest public development package: [build 36](https://github.com/LeValue/KMReader-Porting/releases/tag/v1.0.0-candidate.6).
Stable 1.0 remains gated. See
[1.0 changes](releases/v1.0.0.md), [readiness](ROADMAP_1.0.md) and
[validation](VALIDATION.md). Historical inventory is in the
[repository audit](REPOSITORY_AUDIT.md).

| Task | Document |
|---|---|
| Manage a Komga library remotely | [Debian setup and supported operations](KOMGA_LIBRARY_MANAGEMENT.md) |
| Track the next publication target | [Road to 1.0](ROADMAP_1.0.md) |
| Set up and understand the source tree | [Development](DEVELOPMENT.md) |
| Run checks and understand skipped tests | [Testing](TESTING.md) |
| Build, sign and distribute | [Releasing](RELEASING.md) |
| Understand shared Kindle scripts | [Kindle runtime dependencies](KINDLE_RUNTIME.md) |
| Import local documents into Kindle | [Send to Kindle](KINDLE_IMPORT.md) |
| Track the new remote Kindle management service | [Personal documents, replacement and state migration](KINDLE_LIBRARY_MANAGEMENT.md) |
| Review the 0.9.1 behavior | [Kindle corrections](KINDLE_0.9.1.md), [release notes](releases/v0.9.1-preview.1.md) |
| Review the cleanup and retained history | [Repository audit](REPOSITORY_AUDIT.md), [machine-readable inventory](inventory/repository-before-2026-11-07.json) |
| Finish porting before stable release | [Closure matrix and acceptance criteria](PARITY.md), [settings audit](SETTINGS_AUDIT.md), [reference](IPAD_REFERENCE.md) |
| Review evidence and performance | [Validation history](VALIDATION.md), [performance](PERFORMANCE.md), [Android recovery](ANDROID_EPUB_RECOVERY.md), [EPUB audit](EPUB_RENDERING_AUDIT.md), [comic curl](COMIC_CURL_RENDERING.md) |
| Run personal device diagnostics | [Local Windows tests](LOCAL_WINDOWS_TESTS.md) |
| Reproduce image assets | [Bubble model](BUBBLE_MODEL.md), [tools](../tool/README.md) |
| Read superseded research | [Archive](../archive/README.md) |

`releases/`, `benchmarks/`, `images/` and `screenshots/` retain versioned evidence.
Their measurements and claims apply to the source/hardware named in each record;
they are not automatically evidence for the current checkout.
