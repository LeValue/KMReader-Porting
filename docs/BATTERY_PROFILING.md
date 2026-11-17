# Android battery and frame-time validation

A reported impression of high consumption is a useful starting point, not a
measurement. No phone was connected for this review. Source fixes and host tests
are described in [the code audit](CODE_AUDIT.md); they have not yet demonstrated
a battery saving in mAh or a physical-device frame-rate improvement.

## Compare equivalent builds and conditions

Use a profile/release build, not a debug session, for performance comparisons.
The lifecycle fixes are included in [public build 37/candidate.7](https://github.com/LeValue/KMReader-Porting/releases/tag/v1.0.0-candidate.7),
with signing and native/source CI verified. Build 36 remains available as the
pre-fix comparison; no physical-device energy saving has yet been measured.
Contributors can use `flutter run --profile -d <device-id>` with the pinned SDK.
A locally signed/debug application cannot replace the signed project Preview.

Keep screen brightness, refresh rate, Wi-Fi/cellular conditions, reader settings,
content, starting battery range and test duration equivalent. Do not compare a
charging phone with an unplugged phone or a cold conversion with cached reading.
Let installation and initial sync settle before an idle reading sample.

Measure separate scenarios, ideally repeated in alternating A/B order:

| Scenario | Suggested observation | What to look for |
|---|---|---|
| Dashboard idle, queue empty | 15–20 minutes with screen on and fixed brightness | CPU/network activity without user input; coordinator idle polling is now 15 seconds rather than 1 second. |
| App backgrounded, no transfers | 20–30 minutes after pressing Home, screen off | No periodic UI coordinator checks, Komga reconnect loop or Komf job polling. OS may still schedule permitted work. |
| Same scenario with background downloads disabled | Repeat with a queued synthetic volume | Foreground transfer pauses; no new transfer is admitted until foreground returns. |
| EPUB/comic reading offline | 15–20 minutes, then a fixed set of turns in both directions | Separate display cost from CPU/GPU work, compare cold/warm turns and chapter boundaries. |
| Kindle initial preparation | One redistributable fixture, then a cached reopen | Distinguish conversion/catalog work from steady reading; observe worker shutdown after inactivity. |
| Explicit background download | Same file and network, with permission enabled | Transfer is allowed; check completion, pause/resume and idle behavior afterward. |

The durations are sample windows, not claims that a 1% battery indicator can
resolve an app-specific saving. Repeat coarse measurements; use a supported
power profiler for smaller differences.

## Tools and safe reporting

Start with Android's **Battery → App battery usage**, noting foreground/background
time and the exact build. Android Studio CPU, Memory and System Trace tools can
show threads, wakeups, allocations and frame work. Power profiling availability
depends on device/Android support; record the tool and its limitations.

For native frame diagnostics, with only the intended authorized device attached:

```sh
adb -d shell dumpsys gfxinfo dev.levalue.kmreader.preview framestats
```

Use the actual package ID for a local diagnostic build. Summarize total/janky
frames and frame-time percentiles alongside the measured interaction. This does
not measure energy, and a Flutter frame statistic alone does not measure every
WebView/GPU presentation.

Record build/source, OS/WebView version, generic device model, scenario, duration,
settings and aggregated CPU/network/frame/energy results. Exclude serial numbers,
account names, server addresses, book text, authentication data and unrelated app
usage. Keep full bugreports, traces and raw device dumps private; do not attach
them to public issues without review. No account or personal library access is
needed for the synthetic scenarios.
