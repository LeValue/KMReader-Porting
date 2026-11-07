# Road to 1.0

The next publication target is **1.0.0**. Existing 0.9.x candidates stay in draft
while work continues; previous builds and releases remain available for recovery.
Current source is **1.0.0+30 candidate**; stable publication remains gated by the checks below.
Changing the version number alone does not complete this milestone.

## Working scope

The agreed scope consolidates Android/Windows Komga, Kindle, local reading,
downloads/offline use and progress, plus these requested changes:

- single comic pages: fading departing curl, paper-relative mouse edges/drags;
- import local PC/phone files into the Kindle cloud library;
- hide dictionaries from initial sync and legacy caches, including purchased ones;
- reduce Windows Kindle stalls through asynchronous catalog work and bounded covers.

[1.0 release notes](releases/v1.0.0.md) and [Kindle import](KINDLE_IMPORT.md)
describe behavior and limits. AI/model/translation extensions and upload to a
Komga server are **future features**, excluded from 1.0 acceptance. Existing
experimental settings remain labeled and their persisted configuration is kept.
The broader [parity matrix](PARITY.md) is an inventory, not a promise of full
upstream parity for 1.0.

## Readiness work

| Area | Existing evidence | Work required before calling 1.0 ready |
|---|---|---|
| Continuous verification | [Main CI 42364220405](https://github.com/LeValue/KMReader-Porting/actions/runs/42364220405) passed all three jobs for metadata-recovery source `e19fd64` | Obtain complete CI again for the final 1.0 source; investigate any recurrence of the original transport interruption |
| Reading and offline use | Host, Chromium and native tests cover EPUB, PDF, comic motion, prepared Kindle conversion, local import and offline progress | Check the complete login → browse → download → read → close/reopen journey on target Android and Windows, including interrupted transfer and network loss |
| Data and upgrades | Account-scoped persistence, durable outbox, download resume, cache protection and versioned document tests exist | Verify an in-place upgrade from the signed 0.9.1 build without losing accounts, downloads, progress, bookmarks or preferences; test removing/reconnecting one account while another remains usable |
| Device behavior | Hosted emulator/WebView2 checks and earlier named-device measurements are retained | Validate secure storage/app lock, background downloads, resume, rotation/fullscreen, long-book memory and responsive navigation on actual target hardware; record source and device with results |
| Kindle | Synthetic protocol/conversion tests and earlier account-specific evidence exist; annotation import is one-way | Confirm the supported sign-in/download/offline/resume flow for the 1.0 candidate; describe annotation and first-download limitations accurately |
| Distribution | Retained Android signing certificate, ABI/provenance checks, portable Windows bundle and corresponding worker source are verified for 0.9.1 | Build all three signed Android ABIs and the complete Windows bundle from the final source, verify checksums/licenses and update compatibility, and define the stable 1.0 tag/publication procedure |

These are readiness requirements, not a claim that a 1.0 candidate has already
passed them. Automated checks do not replace target-device acceptance or prove
exact Apple visuals. Do not mark a skipped or unavailable check as passed.

## First observed blocker

[Main CI 42360711583, attempt 1](https://github.com/LeValue/KMReader-Porting/actions/runs/42360711583/attempts/1)
at merge commit `79cf68d` passed Windows and native Android, but the Android host
job failed in `test/live_komga_test.dart` during `DocumentCache.revalidate` for a
PDF. The metadata HEAD request reported an interrupted connection. This is not
yet attributed to an app regression or a server/transport fault.

The same isolated Komga 1.29.1 test passed locally on the unchanged source on
2026-11-07. A new deterministic socket-interruption regression reproduced the
cache failure: conditional HEAD validation bypassed the configured safe-read
retry policy. Metadata HEAD and JSON reads now share that policy, including
response stream failures. Zero retries still means zero retries; authentication
failures and mutation requests are not automatically replayed.

Six new regressions cover cached-document preservation, conditional 304 headers,
response interruption, retry limits and immediate authentication failures. The
real-backend fixture explicitly enables one safe-read retry. This closes the
policy inconsistency; it does not identify why the original server connection
was interrupted. The unchanged source also passed its failed-job retry.
The updated source `e19fd64f13cdf0f5317f44b5e6dc59110fece6bb` passed all three
jobs in [main CI 42364220405](https://github.com/LeValue/KMReader-Porting/actions/runs/42364220405).
Its local signed ARM64 APK retains the original Preview identity/certificate,
version/build and 16 KiB alignment. Target-device upgrade testing remains open.

## Acceptance record

For each candidate, record:

- source SHA, app version/build and full CI run;
- platform/device, OS and relevant WebView/runtime versions;
- result for install/upgrade, login, readers, offline/resume and background work;
- unresolved user-visible defects and the exact supported/unsupported behavior;
- Android signing certificate and ABI checks; complete Windows worker, native
  libraries, notices and corresponding source; downloaded asset digests.

Use [testing](TESTING.md), [validation](VALIDATION.md) and
[releasing](RELEASING.md) as the execution procedures. Production account data
does not belong in logs, fixtures, source archives or CI artifacts.

## Version and publication

Both `pubspec.yaml` and `lib/core/app_version.dart` are 1.0.0+30 for this candidate,
strictly above distributed build 29. Passing the readiness checks is still
required before stable publication. Preserve the
existing Preview application ID and signing certificate for upgrade continuity.
Add accurate 1.0 release notes and embed the exact source in each final build.

The current publisher generates preview tags and marks releases as prereleases;
the final stable 1.0 publication needs an explicit, verified stable-release path.
Do not publish an older draft as a substitute for completing the 1.0 milestone.
