#!/usr/bin/env python3
"""Embed the exact checked-out source in Android/Windows build assets."""
import json
from pathlib import Path
import subprocess

from preview_metadata import read_version

root = Path(__file__).resolve().parent.parent
version, build = read_version(root)
source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
target = root / 'assets/build/source.json'
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps({'source': source, 'version': version, 'build': int(build)}) + '\n')
print(f'Prepared build provenance: {source}, {version}+{build}')
