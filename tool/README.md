# Repository tools

Run commands from the repository root. Install the pinned prerequisites in
[development](../docs/DEVELOPMENT.md) first.

| Area | Entry points | Consumers |
|---|---|---|
| Version/provenance | `preview_metadata.py`, `prepare_build_metadata.py` | Both builds, app About page, release gates |
| Release delivery | `deliver_draft.py`, `apk_delta.py`, `stage_draft_deltas.py` | Exact-source signed APK and Windows delivery; preserve existing releases |
| Kindle runtime | `kindle_personal/`, `kindle_personal_cli.py`, `kindle_android/` | Windows worker and Android Chaquopy; **active app dependencies** |
| Kindle packaging | `build_kindle_worker.ps1`, `package_kindle_prototype.py` | Windows app CI, executable checks, licenses and corresponding source |
| Reader checks | `epub_*_smoke.py`, `kindle_reader_smoke.py`, `android_native_smoke.sh` | Browser/native regression tests |
| Toolchain | `setup_local_flutter.ps1`, `setup_local_android.ps1`, `install_android_ndk.sh` | Hosted/local diagnostic builds |
| Komga administration | `komga_admin/server.py`, `komga_admin/debian/` | Optional Debian upload companion; [setup](../docs/KOMGA_LIBRARY_MANAGEMENT.md) |
| Backend tests | `komga_smoke.py`, `komga_admin/smoke.py` | Isolated real Komga tests |
| Assets/reference | `convert_bubble_detector.py`, `convert_waifu2x.py`, `extract_upstream_settings.py` | Reproduction and settings audit; not startup dependencies |
| Tests | `tests/`, `kindle_personal/tests/` | Packaging, release gates, protocol and conversion regression tests |
