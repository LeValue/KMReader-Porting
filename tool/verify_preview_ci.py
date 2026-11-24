#!/usr/bin/env python3
"""Reuse only successful native/build artifacts for this exact source revision."""
REQUIRED = {
    'android', 'android_reader_display', 'linux_host', 'linux_services',
    'windows', 'windows_host', 'windows_reader', 'windows_worker',
}


def validate_run(run, jobs, source, repository):
    if (run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            run.get('head_sha') != source or run.get('head_branch') != 'main' or
            run.get('event') not in {'push', 'workflow_dispatch'} or
            run.get('path') != '.github/workflows/ci.yml' or
            run.get('repository', {}).get('full_name') != repository):
        raise ValueError('The referenced CI run is not a successful build of this source')
    passed = {job['name'] for job in jobs if job.get('conclusion') == 'success'}
    missing = REQUIRED - passed
    if missing:
        raise ValueError('Required CI jobs did not pass: ' + ', '.join(sorted(missing)))
