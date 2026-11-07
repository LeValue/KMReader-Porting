# Repository tools

Run commands from the repository root. Install the pinned prerequisites in
[development](../docs/DEVELOPMENT.md) first.

| Area | Entry points | Consumers |
|---|---|---|
| Version/provenance | `preview_metadata.py`, `prepare_build_metadata.py` | Both builds, app About page, release gates |
| Release delivery | `stage_preview.py`, `verify_preview_ci.py`, `deliver_draft.py`, `apk_delta.py`, `stage_draft_deltas.py` | Exact-source signed APK and Windows delivery; preserve existing releases |
| Kindle runtime | `kindle_personal/`, `kindle_personal_cli.py`, `kindle_android/` | Windows worker and Android Chaquopy; **active app dependencies** |
| Kindle packaging | `build_kindle_worker.ps1`, `package_kindle_prototype.py` | Windows app CI, executable checks, licenses and corresponding source |
| Reader checks | `epub_*_smoke.py`, `kindle_reader_smoke.py`, `android_native_smoke.sh` | Browser/native regression tests |
| Device diagnostics | `windows_*.ps1`, `android_epub_recovery.ps1`, `find_cached_alice.ps1`, `epub_responsiveness.dart` | Manual diagnostics on an explicitly selected PC/device |
| Toolchain | `setup_local_flutter.ps1`, `setup_local_android.ps1`, `install_android_ndk.sh` | Hosted/local diagnostic builds |
| Backend | `komga_smoke.py` | Isolated real Komga test |
| Assets/reference | `convert_bubble_detector.py`, `convert_waifu2x.py`, `extract_upstream_settings.py` | Reproduction and settings audit; not startup dependencies |
| Tests | `tests/`, `kindle_personal/tests/` | Packaging, release gates, protocol and conversion regression tests |

`package_kindle_prototype.py` retains its name for existing imports and source
rebuild recipes. It packages the current worker too. Historical research and
the old standalone workflow live in [archive](../archive/README.md).
