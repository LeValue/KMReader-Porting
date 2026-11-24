# Kindle runtime

The shared Python modules in `tool/kindle_personal/` are part of the app's
Kindle integration.

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

Python dependencies are pinned in `tool/kindle_personal/requirements.txt`.
Android pins its Chaquopy dependencies in Gradle. Windows distributions
include the worker, its notices and a corresponding-source archive. See
[Kindle license notices](../assets/kindle/NOTICE.md).
