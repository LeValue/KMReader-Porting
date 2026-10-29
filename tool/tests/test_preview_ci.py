import copy
import unittest

from tool.verify_preview_ci import validate_run


class PreviewGateTest(unittest.TestCase):
    def setUp(self):
        self.run = {'status': 'completed', 'conclusion': 'success', 'head_sha': 'a' * 40,
                    'head_branch': 'main', 'event': 'push', 'path': '.github/workflows/ci.yml',
                    'repository': {'full_name': 'LeValue/KMReader-Porting'}}
        self.jobs = [{'name': name, 'conclusion': 'success'} for name in
                     ['android', 'windows', 'android_reader_display']]

    def verify(self, run=None, jobs=None):
        validate_run(run or self.run, self.jobs if jobs is None else jobs,
                     'a' * 40, 'LeValue/KMReader-Porting')

    def test_exact_successful_run_is_accepted(self):
        self.verify()

    def test_other_source_branch_workflow_event_or_repository_is_rejected(self):
        variants = {'head_sha': 'b' * 40, 'head_branch': 'other',
                    'event': 'pull_request', 'path': '.github/workflows/other.yml',
                    'repository': {'full_name': 'other/repository'},
                    'status': 'in_progress', 'conclusion': 'failure'}
        for key, value in variants.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify(run={**self.run, key: value})

    def test_each_failed_skipped_cancelled_or_missing_required_job_is_rejected(self):
        for index in range(3):
            for conclusion in ['failure', 'skipped', 'cancelled', None]:
                jobs = copy.deepcopy(self.jobs)
                jobs[index]['conclusion'] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(ValueError):
                    self.verify(jobs=jobs)
            with self.assertRaises(ValueError):
                self.verify(jobs=self.jobs[:index] + self.jobs[index + 1:])


if __name__ == '__main__':
    unittest.main()
