"""Package only explicit prototype inputs; never glob a user's data directory."""

import argparse
import hashlib
import importlib.metadata
import json
import shutil
import zipfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary-directory", type=Path, required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--smoke-report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    prototype = repository / "tool" / "kindle_personal"
    output = args.output.resolve()
    stage = output / "stage"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    shutil.copytree(args.binary_directory, stage / "KMReader-Kindle")
    shutil.copyfile(prototype / "README.md", stage / "LEGGIMI.md")
    shutil.copyfile(prototype / "Avvia-Kindle.cmd", stage / "Avvia-Kindle.cmd")
    shutil.copyfile(repository / "LICENSE", stage / "LICENSE")
    smoke = json.loads(args.smoke_report.read_text())
    if (
        smoke.get("windows_dpapi") != "passed"
        or smoke.get("browser_callback") != "passed"
        or smoke.get("amazon_contacted") is not False
    ):
        raise ValueError(
            "Packaged executable must pass Windows DPAPI and browser smoke tests"
        )
    shutil.copyfile(args.smoke_report, stage / "verification.json")
    # Include installed distribution notices (also those of transitive runtime
    # dependencies). Node/Playwright notices are already included by collect-all.
    notices = stage / "THIRD_PARTY_LICENSES"
    notices.mkdir()
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
    }
    (stage / "build.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    archive = output / f"KMReader-Kindle-{smoke['prototype_version']}-windows-x64.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                bundle.write(path, path.relative_to(stage).as_posix())
    sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(
        sha + "  " + archive.name + "\n", encoding="ascii"
    )
    print(json.dumps({"file": archive.name, "sha256": sha, "source": args.source}))


if __name__ == "__main__":
    main()
