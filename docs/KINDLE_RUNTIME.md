# Kindle runtime dependency map

Audited against working app source `a5e51aa44e59a4ff5d01dedfb83a70c53c126aa7`
(0.9.1+29). The package name `kindle_personal` predates integration; its old
description claiming no app dependency was incorrect.

| Consumer | Required path / boundary |
|---|---|
| Flutter app | `lib/core/kindle/` and Kindle auth/settings pages; the server repository selects the Kindle adapter |
| Windows conversion and covers | `NativeKindlePreparation` → `kindle/KMReader-Kindle.exe rpc-json` → `native_rpc.py` → `prepare.py`, `cover.py` |
| Windows compatibility login/import | `conversion.dart` → same executable `connect-json` → `cli.py`, browser/auth/client/storage modules; imports existing protected sessions |
| Windows packaging | `build_kindle_worker.ps1` → `kindle_personal_cli.py` → `__main__.py`; PyInstaller collects runtime libraries; `package_kindle_prototype.py` includes licenses and corresponding source |
| Android conversion/covers | `KindlePlugin.kt` → `tool/kindle_android/kmreader_kfx.py` → generated `kindle_personal` module subset |
| Chaquopy source subset | `android/app/build.gradle.kts` copies `__init__.py`, `mapped_kfx.py`, `prepare.py`, `common.py`, `cover.py`, `range_source.py`, `kfx_progressive.py` |
| Lazy conversion imports | `prepare.py` can import `kfx_conversion.py` on Windows, which imports `mapped_kfx.py`; Android implements its conversion entry directly in `kmreader_kfx.py` |
| Shared cover path | `cover.py` → `kfx_progressive.py`, `range_source.py`, `common.py` |
| Self-check / migration / diagnostics | `selfcheck.py`, `probe_fixtures.py`, `probe.py`, `services_probe.py`, retained CLI/catalog/download/resource modules and `storage.py` |

Keep the entire Python package for this cleanup. Deleting only the apparent
standalone CLI/auth modules would also break compatibility login, frozen worker
self-tests, existing-session migration and read-only diagnostic workflows.
The launcher `Avvia-Kindle.cmd` is an explicit packaging input, so it stays too.
Tests include dynamic imports, subprocess conversion and actual prepared-book
imports; a text search for Flutter imports alone is insufficient.

Python dependencies stay pinned in `tool/kindle_personal/requirements.txt`.
Android separately pins Chaquopy-compatible lxml/Pillow versions and the same
kfxlib source revision in Gradle. These intentionally differ from the Windows
wheels; do not merge or upgrade them as part of a repository cleanup.
Flutter's locked packages and all three local `third_party/` overrides also
remain unchanged.

The companion version **0.3.1** is not the app version **0.9.1+29**.
Both native builds must retain `assets/kindle/COPYING`, `NOTICE.md`, the pinned
kfxlib source and the source archive produced with the Windows worker.
The worker receives local paths and bounded cover capabilities; app-side
request signing remains in Dart.

Only superseded research documents, two browser experiments and the former
standalone release workflow move to `archive/`. The active CI owns protocol,
browser, prepared import and worker packaging checks. Personal-account probes
stay manual and are not dispatched by CI.

## Native Dart document management (build 31)

`send_login.dart` and `import.dart` handle dedicated Send-to-Kindle authorization
and upload. `management.dart` handles PDOC-only remote deletion, account-scoped
backups/journals and acceptance readback; `document_edit.dart` prepares a new EPUB
without altering its original. These paths do not replace or remove the Python
conversion/runtime modules listed above. Complete cloud bookmark/state migration
remains unimplemented; see [management limits](KINDLE_LIBRARY_MANAGEMENT.md).

The existing locked `image` 4.12.0 package now belongs to production dependencies
for JPEG/PNG cover validation, resizing and encoding in a worker isolate. Its
version is unchanged; no Python/native dependency or override was upgraded.
