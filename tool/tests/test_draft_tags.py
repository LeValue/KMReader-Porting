import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from deliver_draft import candidate_tag_matches


class DraftTagsTest(unittest.TestCase):
    def test_versioned_release_and_candidate_drafts(self):
        for tag in ('v1.0.0', 'v1.0.0-candidate.1', 'v1.0.0-epub-candidate.12'):
            with self.subTest(tag=tag):
                self.assertTrue(candidate_tag_matches('1.0.0', tag))

    def test_other_versions_and_non_candidate_tags_are_rejected(self):
        for tag in ('v0.9.1', 'v1.0.1', 'v1X0X0', 'v1.0.0-preview.1',
                    'v1.0.0-candidate.0', 'v1.0.0-candidate.01', 'v1.0.0-candidate.1-extra'):
            with self.subTest(tag=tag):
                self.assertFalse(candidate_tag_matches('1.0.0', tag))


if __name__ == '__main__':
    unittest.main()
