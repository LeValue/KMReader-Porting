#!/usr/bin/env python3
"""Reuse only successful native/build artifacts for this exact source revision."""
import json
import os
from pathlib import Path
import re
import subprocess

REQUIRED = {'android', 'windows', 'android_reader_display'}


def validate_run(run, jobs, source, repository):
    if (run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            run.get('head_sha') != source or run.get('head_branch') != 'main' or
            run.get('event') not in {'push', 'workflow_dispatch'} or
            run.get('path') != '.github/workflows/ci.yml' or
            run.get('repository', {}).get('full_name') != repository):
        raise ValueError('The referenced CI run is not a successful build of this source')
    passed = {job['name'] for job in jobs if job.get('conclusion') == 'success'}
    if not REQUIRED <= passed:
        raise ValueError('Android, Windows and native Android checks must all pass')


def main():
    repository = os.environ['GH_REPO']
    requested = os.environ.get('VERIFIED_RUN', '')
    results = json.loads(os.environ['CURRENT_BUILD_RESULTS'])
    if requested:
        if not re.fullmatch('[1-9][0-9]*', requested):
            raise SystemExit('Invalid verification run identifier')
        if any(results.get(job, {}).get('result') != 'skipped' for job in REQUIRED):
            raise SystemExit('Artifact reuse must explicitly skip the duplicate build jobs')
        def api(path):
            return json.loads(subprocess.check_output(['gh', 'api', path]))
        run = api(f'repos/{repository}/actions/runs/{requested}')
        jobs, page = [], 1
        while True:
            response = api(f'repos/{repository}/actions/runs/{requested}/jobs?per_page=100&page={page}')
            jobs.extend(response['jobs'])
            if len(jobs) >= response['total_count']:
                break
            if not response['jobs']:
                raise SystemExit('Incomplete verification job listing')
            page += 1
        validate_run(run, jobs, os.environ['GITHUB_SHA'], repository)
        artifact_run = requested
    else:
        if any(results.get(job, {}).get('result') != 'success' for job in REQUIRED):
            raise SystemExit('All current build and native integration jobs must pass')
        artifact_run = os.environ['GITHUB_RUN_ID']
    with Path(os.environ['GITHUB_ENV']).open('a') as output:
        output.write(f'ARTIFACT_RUN={artifact_run}\n')
    print('Verified Android, Windows and native integration artifacts from run ' + artifact_run)


if __name__ == '__main__':
    main()
