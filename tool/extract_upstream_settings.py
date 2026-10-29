#!/usr/bin/env python3
"""Extract persisted settings and structured reader/translation fields from upstream."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def extract(root):
    source = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    base = root / 'KMReader'
    options = {}
    files = set((base / 'Features/Settings').rglob('*.swift'))
    for name in ['MangaTranslationSettingsView.swift', 'MangaProviderEditorView.swift', 'MangaProviderManagementView.swift', 'MangaModelManagementView.swift', 'EpubOverlayPreferencesEditor.swift']:
        files.update(base.rglob(name))
    files.update(base.rglob('*CustomFont*View*.swift'))
    files.update(base.rglob('*Preset*View*.swift'))
    controls = []
    sources = {}
    for path in sorted(files):
        content = path.read_text()
        sources[str(path.relative_to(root))] = hashlib.sha256(content.encode()).hexdigest()
        for line_number, line in enumerate(content.splitlines(), 1):
            match = re.match(r'\s*(Toggle|Picker|Slider|Stepper|TextField|SecureField|NavigationLink|Button|Link|EditButton)\s*[(<{]', line)
            if match:
                controls.append({'kind': match.group(1), 'expression': line.strip(), 'file': str(path.relative_to(root)), 'line': line_number})
        for match in re.finditer(r'@AppStorage\("([^"\n]+)"\)\s*(?:private\s+)?var\s+(\w+)(?:\s*:\s*([^=\n]+))?\s*=\s*([^\n]+)', content):
            key, name, kind, default = match.groups()
            entry = options.setdefault(key, {'key': key, 'type': kind.strip() if kind else 'inferred', 'default_expression': default.strip(), 'origins': []})
            entry['origins'].append({'file': str(path.relative_to(root)), 'line': content[:match.start()].count('\n') + 1})
    models = [
        'Features/Reader/Models/Epub/EpubThemePreferences.swift',
        'Features/Reader/Models/Epub/EpubOverlayPreferences.swift',
        'Features/MangaTranslation/Models/MangaTranslationPreferences.swift',
        'Features/MangaTranslation/Models/MangaProviderConfig.swift',
        'Core/Models/ModelLibraryConfiguration.swift',
        'Features/Dashboard/Models/DashboardSection.swift',
    ]
    for model in models:
        path = base / model
        if not path.exists():
            continue
        content = path.read_text()
        sources[str(path.relative_to(root))] = hashlib.sha256(content.encode()).hexdigest()
        scope = content
        type_name = path.stem
        if path.stem == 'DashboardSection':
            type_name = 'DashboardConfiguration'
            scope = content[content.index('struct DashboardConfiguration:'):]
        for match in re.finditer(r'^  var (\w+): ([^\n{]+)$', scope, re.M):
            name, kind = match.groups()
            key = type_name + '.' + name
            options[key] = {'key': key, 'type': kind.strip() if kind else 'inferred', 'origins': [{'file': str(path.relative_to(root)), 'line': content[:content.index(scope) + match.start()].count('\n') + 1}]}
    return {'upstream': 'https://github.com/kmworks/kmreader', 'source': source, 'options': sorted(options.values(), key=lambda entry: entry['key']), 'controls': controls, 'files_sha256': dict(sorted(sources.items()))}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('repository', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    inventory = extract(args.repository)
    encoded = json.dumps(inventory, ensure_ascii=False, indent=2) + '\n'
    if args.check:
        if args.output.read_text() != encoded:
            raise SystemExit('Upstream settings inventory differs from the source')
    else:
        args.output.write_text(encoded)
    print(f"Extracted {len(inventory['options'])} persisted keys/structured fields from {inventory['source']}")


if __name__ == '__main__':
    main()
