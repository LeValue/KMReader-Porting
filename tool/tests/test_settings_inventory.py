import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'extract_upstream_settings.py'
spec = importlib.util.spec_from_file_location('settings_inventory', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SettingsInventoryTest(unittest.TestCase):
    def test_every_inventory_key_has_an_explicit_implementation_or_gap(self):
        root = SCRIPT.parent.parent
        inventory = json.loads((root / 'docs/upstream-settings.json').read_text())
        audit = json.loads((root / 'docs/upstream-settings-support.json').read_text())
        self.assertEqual(audit['upstream_source'], inventory['source'])
        self.assertEqual(set(audit['options']), {entry['key'] for entry in inventory['options']})
        statuses = {'implemented', 'adapted', 'internal', 'partial', 'platform-unavailable'}
        for entry in audit['options'].values():
            self.assertIn(entry['status'], statuses)
            self.assertTrue((root / entry['implementation']).is_file())
            if entry['status'] != 'implemented':
                self.assertTrue(entry['note'])

    def test_extracts_nested_inferred_storage_and_ignores_computed_model_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            settings = root / 'KMReader/Features/Settings/Example.swift'
            settings.parent.mkdir(parents=True)
            settings.write_text('''@AppStorage("network") private var timeout: Double = 15
@AppStorage("network") var sameValue: Double = 15
Toggle("Enabled", isOn: $enabled)
''')
            nested = root / 'KMReader/Features/MangaTranslation/Views/MangaModelManagementView.swift'
            nested.parent.mkdir(parents=True)
            nested.write_text('@AppStorage("modelLibrary") private var library = ModelLibraryConfiguration()\nButton("Download") {}\n')
            model = root / 'KMReader/Features/Reader/Models/Epub/EpubThemePreferences.swift'
            model.parent.mkdir(parents=True)
            model.write_text('''struct EpubThemePreferences {
  var fontWeight: Double?
  var computed: Double { 1 }
}
''')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'fixture'], check=True)
            result = module.extract(root)
            self.assertEqual(result, module.extract(root))
            options = {entry['key']: entry for entry in result['options']}
            self.assertEqual(len(options['network']['origins']), 2)
            self.assertEqual(options['modelLibrary']['type'], 'inferred')
            self.assertIn('EpubThemePreferences.fontWeight', options)
            self.assertNotIn('EpubThemePreferences.computed', options)
            self.assertEqual([entry['kind'] for entry in result['controls']], ['Button', 'Toggle'])
            self.assertEqual(result['controls'][0]['line'], 2)
            before = result['files_sha256'][str(nested.relative_to(root))]
            output = root / 'inventory.json'
            output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
            subprocess.run(['python3', str(SCRIPT), str(root), '--output', str(output), '--check'], check=True, capture_output=True)
            nested.write_text(nested.read_text() + '// changed\n')
            self.assertNotEqual(module.extract(root)['files_sha256'][str(nested.relative_to(root))], before)
            changed = subprocess.run(['python3', str(SCRIPT), str(root), '--output', str(output), '--check'], capture_output=True)
            self.assertNotEqual(changed.returncode, 0)


if __name__ == '__main__':
    unittest.main()
