# Tests on an interactive Windows PC

[Local Windows diagnostics](https://github.com/LeValue/KMReader-Porting/actions/workflows/local-windows.yml)
is a manual workflow for a registered self-hosted Windows x64 runner. Start the
runner with `run.cmd` in the signed-in desktop session, rather than installing it
as a service. Keep the desktop unlocked and the test application visible. The
workflow uses the runner's default `self-hosted`, `Windows`, `X64` labels plus
the selected `runner_label`. For the laptop, register the additional label
`kmreader-laptop` and select it when starting the workflow. Select `self-hosted`
only to use the original unrestricted Windows runner selection. The laptop
label keeps jobs off the desktop when both machines are connected.

Choose **Run workflow** and one of these modes:

| Mode | Work performed |
|---|---|
| `inspect` | Read GPU/driver, current display mode, desktop-session and build-prerequisite information. |
| `native` | Build on a GitHub-hosted Windows runner, then execute the existing reader regression suite locally in debug mode. |
| `profile` | Build on a GitHub-hosted Windows runner, then measure EPUB locally in profile mode with natural native frame scheduling. |
| `responsiveness` | Build a standalone release probe on GitHub, smoke test it there, then measure first/following input, idle, scrolling and settings on the selected PC. No local Flutter SDK is needed. |

The first build downloads Flutter 3.47.8 into the runner tool cache and checks
the archive against the official release manifest's SHA256. Pub dependencies
also use a runner-specific cache. The local PC needs WebView2 Runtime. Compiling
the test application on GitHub avoids requiring local C++ tools or enabling
Windows Developer Mode for plugin symlinks. The local driver resolves Dart
packages without generating plugin links, then launches the downloaded native
application using `--use-application-binary`. The diagnostic executable has a
separate Windows product identity and WebView cache. These jobs do not install
system-wide toolchains or change Windows developer settings.

Artifacts are retained for seven days. `local-windows-diagnostics` contains the
environment report and command logs. Profile mode also writes
`epub-frame-times.json`, including partial phase results when later phases fail.
The fixture has two chapters of 1,400 generated paragraphs each. The database
and publication live in test-owned memory/temporary storage; the benchmark does
not import the user's library or upload books.

For profile mode, `publication: alice-gutenberg` downloads Project Gutenberg's
public EPUB of *Alice's Adventures in Wonderland* into the runner's temporary
directory. Its byte count and SHA256 are recorded in the report. This is a
reference edition and is not assumed to match a user's copy on Komga.

`publication: cached-alice` instead locates the requested download in KMReader's
standard application storage. It reads only EPUB ZIP metadata beneath the
application's downloaded-book directories, with a bounded search. It requires
exactly one matching title, opens that EPUB read-only and records only its size
and hash. It does not read account databases or credentials. The publication
stays on the PC; only diagnostics are uploaded. A missing or ambiguous download
requires an explicit file path rather than silently substituting another book.

## Reading the profile report

The phases are a Flutter sheet baseline, idle EPUB, four automatic slide turns,
four automatic curl turns, three seconds of vertical scrolling and three opens
of the reader's actual text-settings sheet. Motion is warmed before measurement.
The test rejects unavailable animation paths, hidden browser documents and
unchanged navigation. Windows animation effects must be enabled.

| Report field | Meaning |
|---|---|
| `webViewRaf.intervals` | Browser animation-callback intervals in milliseconds, including stalls. These callbacks do not establish physical monitor presentation FPS. |
| `captureBefore` / `captureAfter` | Native WebView capture and GPU-copy counters surrounding the action. An unchanged idle page does not need new captures. |
| `flutterBuildMs` / `flutterRasterMs` | Flutter build and raster duration for reported engine frames. Callbacks are batched; the collector also drains the tail after each action. |
| `flutterVsyncMicros` | Engine frame timestamps, useful for locating gaps between rendered Flutter frames. |
| `browser` / `webGlRenderer` | Actual viewport, pixel ratio, motion preference and GPU renderer used by the EPUB. |

The test uses `fullyLive` scheduling and real asynchronous waits. It does not
force frames through repeated synthetic 16 ms `pump` calls. These observations
help separate browser work, capture delivery and Flutter rendering. They do not
replace presentation traces or a reproduction with the particular book, window
size and input that causes a problem. The baseline sheet and reader settings
also have different contents, so their timing difference alone cannot establish
that WebView is the cause.

The `responsiveness` mode uses the application's normal `WidgetsFlutterBinding`.
Unlike the `fullyLive` integration harness, it does not request frames while
idle. It records actual reader button and settings callbacks, a first turn
without an artificial warm-up, subsequent turns, vertical wheel input, browser
task/layout/heap counters and capture delivery. Flutter timings are filtered by
their wall-clock raster timestamp to exclude batched frames from earlier phases.
The launcher samples CPU time and memory only for the diagnostic process and
its WebView2 descendants. It records no process command lines or user-library
content. `responsiveness.json` and `process-samples.json` share epoch timestamps
for correlating input latency with CPU and memory use. The hosted smoke report
is a harness check, not a substitute for measurements on the selected laptop.
