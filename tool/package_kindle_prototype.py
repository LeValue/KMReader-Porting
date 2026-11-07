"""Package the shared Kindle worker and its corresponding source from explicit inputs."""

import argparse
import hashlib
import importlib.metadata
import json
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

KFX_SOURCE = "fc00a7b7a04badfbd61f3e42aaaa5e45e1d0cfd7"


def source_bundle(repository, dependency, output, version, metadata):
    archive = output / f"KMReader-Kindle-{version}-source.zip"
    # Explicit source inputs only. Artifacts, credentials and real book files
    # are never considered, even if they are present beside the build directory.
    paths = [
        *sorted((repository / "tool/kindle_personal").rglob("*.py")),
        *sorted((repository / "tool/kindle_personal").rglob("*.dart")),
        *sorted((repository / "tool/kindle_personal").glob("*.md")),
        *sorted((repository / "tool/kindle_personal").glob("*.cmd")),
        repository / "tool/kindle_personal/requirements.txt",
        repository / "tool/kindle_personal_cli.py",
        repository / "tool/package_kindle_prototype.py",
        repository / ".github/workflows/ci.yml",
        repository / "archive/kindle-prototype/kindle-prototype.yml",
        repository / "archive/kindle-prototype/README.md",
        repository / "archive/kindle-prototype/RELEASE_NOTES.md",
        repository / "archive/README.md",
        repository / "tool/README.md",
        repository / "docs/README.md",
        repository / "docs/KINDLE_RUNTIME.md",
        repository / "docs/DEVELOPMENT.md",
        repository / "docs/TESTING.md",
        repository / "docs/RELEASING.md",
        repository / "assets/kindle/COPYING",
        repository / "assets/kindle/NOTICE.md",
        *sorted((repository / "tool/kindle_android").glob("*.py")),
        repository / "tool/build_kindle_worker.ps1",
        repository / "android/app/build.gradle.kts",
        repository / "android/settings.gradle.kts",
        repository / "android/app/src/main/kotlin/dev/levalue/kmreader/KindlePlugin.kt",
    ]
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in paths:
            if not path.is_file():
                continue
            bundle.write(path, path.relative_to(repository).as_posix())
        for path in sorted(dependency.rglob("*")):
            if (
                path.is_file()
                and "__pycache__" not in path.parts
                and path.suffix != ".pyc"
            ):
                bundle.write(
                    path, "vendor/kfxlib/" + path.relative_to(dependency).as_posix()
                )
        bundle.write(dependency / "COPYING", "LICENSE")
        bundle.write(repository / "LICENSE", "MIT-LICENSE")
        bundle.writestr("build.json", json.dumps(metadata, indent=2) + "\n")
        bundle.writestr(
            "requirements-build.txt",
            "\n".join(
                "./vendor/kfxlib" if name.lower() == "kfxlib" else f"{name}=={version}"
                for name, version in sorted(metadata["dependencies"].items())
            )
            + "\n",
        )
        bundle.writestr(
            "REBUILD.md",
            """# Corresponding source for the standalone Kindle companion

The combined companion executable is distributed under GPL-3.0-or-later.
Original KMReader code retains its MIT notices; the Flutter app is separate.
John Howell's kfxlib source and COPYING are included, pinned in build.json.

Windows x64, Python 3.11, Chrome or Edge installed:

```powershell
python -m venv build-env
build-env/Scripts/python.exe -m pip install -r requirements-build.txt
build-env/Scripts/python.exe -m PyInstaller --noconfirm --clean --onedir --name KMReader-Kindle --paths tool --collect-all playwright --collect-submodules amazon.ion --collect-all kfxlib --collect-all lxml --collect-all PIL --collect-all bs4 tool/kindle_personal_cli.py
dist/KMReader-Kindle/KMReader-Kindle.exe self-test --browser
```

No Amazon account or personal documents are needed to build or test.
The active ci.yml workflow reproduces protocol tests and Windows packaging;
native Flutter import tests use the full KMReader repository at build.json's source.
Dependency versions and bundled license notices accompany the binary package.
""",
        )
    return archive


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary-directory", type=Path, required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--smoke-report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--kfx-source-repository", type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    prototype = repository / "tool" / "kindle_personal"
    revision = subprocess.check_output(
        [
            "git",
            "-C",
            str(args.kfx_source_repository),
            "rev-parse",
            "HEAD",
        ],
        text=True,
    ).strip()
    if revision != KFX_SOURCE:
        raise ValueError("KFX source must match the pinned dependency revision")
    dependency = args.kfx_source_repository / "vendor/kfxlib"
    output = args.output.resolve()
    stage = output / "stage"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    shutil.copytree(args.binary_directory, stage / "KMReader-Kindle")
    shutil.copyfile(prototype / "README.md", stage / "LEGGIMI.md")
    shutil.copyfile(
        repository / "archive/kindle-prototype/README.md", stage / "PROTOTYPE-GUIDE.md"
    )
    shutil.copyfile(prototype / "Avvia-Kindle.cmd", stage / "Avvia-Kindle.cmd")
    shutil.copyfile(dependency / "COPYING", stage / "LICENSE")
    shutil.copyfile(repository / "LICENSE", stage / "MIT-LICENSE")
    smoke = json.loads(args.smoke_report.read_text())
    if (
        smoke.get("windows_dpapi") != "passed"
        or smoke.get("browser_callback") != "passed"
        or smoke.get("browser_callback_chrome") != "passed"
        or smoke.get("browser_callback_edge") != "passed"
        or smoke.get("offline_kfx_conversion") != "passed"
        or smoke.get("progressive_kfx_decoding") != "passed"
        or smoke.get("kindle_position_roundtrip") != "passed"
        or smoke.get("amazon_contacted") is not False
    ):
        raise ValueError(
            "Packaged executable must pass DPAPI, both browsers and offline KFX conversion"
        )
    shutil.copyfile(args.smoke_report, stage / "verification.json")
    # Include installed distribution notices (also those of transitive runtime
    # dependencies). Node/Playwright notices are already included by collect-all.
    notices = stage / "THIRD_PARTY_LICENSES"
    notices.mkdir()
    python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if python_license.is_file():
        shutil.copyfile(python_license, notices / "Python-LICENSE.txt")
    dependencies = {}
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata["Name"]
        if name.lower() in ("pip", "setuptools", "wheel"):
            continue
        dependencies[name] = distribution.version
        for file in distribution.files or []:
            if any(
                part.lower().startswith(("license", "copying", "notice", "copyright"))
                for part in file.parts
            ):
                path = Path(distribution.locate_file(file))
                if path.is_file():
                    target = notices / name / Path(*file.parts[-2:])
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, target)
    metadata = {
        "schema": 1,
        "source": args.source,
        "prototype_version": smoke["prototype_version"],
        "marketplace": "amazon.it",
        "platform": "windows-x64",
        "dependencies": dependencies,
        "distribution_license": "GPL-3.0-or-later",
        "kfxlib_source": "https://github.com/kafkasl/ksync",
        "kfxlib_revision": KFX_SOURCE,
    }
    (stage / "build.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    archive = output / f"KMReader-Kindle-{smoke['prototype_version']}-windows-x64.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                bundle.write(path, path.relative_to(stage).as_posix())
    sources = source_bundle(
        repository, dependency, output, smoke["prototype_version"], metadata
    )
    sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(
        "".join(
            hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n"
            for path in (archive, sources)
        ),
        encoding="ascii",
    )
    print(json.dumps({"file": archive.name, "sha256": sha, "source": args.source}))


if __name__ == "__main__":
    main()
