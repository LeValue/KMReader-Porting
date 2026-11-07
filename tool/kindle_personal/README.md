# Shared Kindle worker

This directory is an active dependency of KMReader 0.9.1. Its historical name
does not mean the package can be removed with the standalone prototype.

Android copies a selected module set into Chaquopy; Windows freezes the CLI and
JSON-lines worker into `kindle/KMReader-Kindle.exe`. See the
[dependency map](../../docs/KINDLE_RUNTIME.md) before moving any module.
`VERSION` in `__init__.py` identifies the companion protocol/package (0.3.1),
not the Flutter app version (0.9.1+29).

The old standalone user guide and release notes are preserved in
[the prototype archive](../../archive/kindle-prototype/README.md).
Existing launchers, account migration and read-only probes remain supported by
the current worker. No standalone prototype release is produced automatically.

Build and test the worker from the repository root with
`./tool/build_kindle_worker.ps1` on Windows. The script runs the Python suite,
builds the executable, checks DPAPI/Chrome/Edge and offline conversion, and
packages dependency notices and corresponding source. The executable and source
archive must accompany the Windows app; see [releasing](../../docs/RELEASING.md).
