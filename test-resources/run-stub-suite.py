#!/usr/bin/env python3
"""
Run every job of .github/workflows/push-stub-run.yml on this machine.

The job list is read from the workflow file, so this cannot drift from CI: every positive
config (with its upload-manifest check), every negative case, every Slack case, on every
Nextflow version in the matrix, plus the script-quoting check.

Each job runs in its own throw-away copy of the working tree (uncommitted and untracked
files included, since those are what you are testing), with its own secrets file, so nothing
lands in the working tree and your real Nextflow secrets are never read or changed.

  Usage: test-resources/run-stub-suite.py [options]

    --versions 25.10.4,26.04.0   Nextflow versions to run (default: the CI matrix)
    --jobs N                     jobs to run at once (default: half the CPUs, at most 6)
    --only TEXT                  run only jobs whose name contains TEXT (repeatable)
    --keep-failed                keep the repository copy of each failed job
    --out FILE                   also write one line per job to FILE (TSV)

Needs: nextflow on PATH, PyYAML, and a Java that every requested Nextflow version supports.
Nextflow 24.10 does not run on Java newer than 22; CI pins Java 21. Point JAVA_HOME at one:

    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 test-resources/run-stub-suite.py

Exit status is 0 only when every job passed. See TESTING.md.
"""
import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

try:
    import yaml
except ImportError:
    sys.exit('PyYAML is needed to read the CI workflow file: pip install pyyaml')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW_FILE = os.path.join(REPO, '.github', 'workflows', 'push-stub-run.yml')
JOB_TIMEOUT_SECONDS = 900
PLACEHOLDER_KEY = {'name': 'PANORAMA_API_KEY', 'value': 'ci-stub-not-a-real-key'}
NOT_COPIED = shutil.ignore_patterns('.git', 'work', '.nextflow', '.nextflow.log*', 'results',
                                    'reports', '.nf-cache', 'mzml_cache', 'raw_cache')


def read_ci_jobs():
    """Return (versions, jobs) from the CI workflow file. A job is a dict with kind and name."""
    with open(WORKFLOW_FILE) as handle:
        ci = yaml.safe_load(handle)['jobs']
    versions = ci['stub-run']['strategy']['matrix']['nextflow-version']
    jobs = []
    for config in ci['stub-run']['strategy']['matrix']['config']:
        jobs.append({'kind': 'positive', 'name': config, 'config': config})
    for case in ci['negative-stub-run']['strategy']['matrix']['case']:
        jobs.append({'kind': 'negative', 'name': case['config'], 'config': case['config'],
                     'expect': case['expect']})
    for case in ci['slack-stub-run']['strategy']['matrix']['case']:
        jobs.append({'kind': 'slack', 'name': case['name'], 'expect': case['expect'],
                     'config': 'test-slack-notifications.config', 'secret': case['secret']})
    return versions, jobs


def run_job(job, version, base_dir, keep_failed):
    """Run one job the way CI does. Returns (passed, note, seconds)."""
    started = time.time()
    job_dir = tempfile.mkdtemp(prefix='job-', dir=base_dir)
    repo_copy = os.path.join(job_dir, 'repo')
    shutil.copytree(REPO, repo_copy, symlinks=True, ignore=NOT_COPIED)

    # As in CI: only the positive jobs get the placeholder Panorama key.
    secrets = [PLACEHOLDER_KEY] if job['kind'] == 'positive' else []
    if job.get('secret'):
        secrets.append({'name': 'SLACK_WEBHOOK_URL', 'value': job['secret']})
    secrets_file = os.path.join(job_dir, 'secrets.json')
    with open(secrets_file, 'w') as handle:
        json.dump(secrets, handle)
    os.chmod(secrets_file, 0o600)

    env = dict(os.environ, NXF_VER=version, NXF_SECRETS_FILE=secrets_file, NXF_ANSI_LOG='false')
    try:
        run = subprocess.run(
            ['nextflow', 'run', '.', '-stub-run',
             '-c', 'test-resources/' + job['config'], '-c', 'test-resources/ci.config'],
            cwd=repo_copy, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            timeout=JOB_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        note = 'no result after %d s' % JOB_TIMEOUT_SECONDS
        if keep_failed:
            note += ' (kept: %s)' % repo_copy
        else:
            shutil.rmtree(job_dir, ignore_errors=True)
        return False, note, time.time() - started
    output = run.stdout
    with open(os.path.join(repo_copy, 'nextflow.out'), 'w') as handle:
        handle.write(output)

    if job['kind'] == 'positive':
        passed = run.returncode == 0
        note = 'exit=%d' % run.returncode
        if passed:
            check = subprocess.run(['test-resources/check-upload-manifest.sh', job['config']],
                                   cwd=repo_copy, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
            passed = check.returncode == 0
            note = check.stdout.strip().splitlines()[-1] if check.stdout.strip() else note
        else:
            errors = [line.strip() for line in output.splitlines() if 'ERROR' in line]
            note += ' ' + ' | '.join(errors[:2])
    elif job['kind'] == 'negative':
        found = job['expect'] in output
        passed = run.returncode != 0 and found
        note = 'exit=%d expected-message-found=%s' % (run.returncode, found)
    else:
        found = job['expect'] in output
        log_file = os.path.join(repo_copy, '.nextflow.log')
        log = open(log_file).read() if os.path.exists(log_file) else ''
        leaked = bool(job['secret']) and (job['secret'] in output or job['secret'] in log)
        passed = run.returncode == 0 and found and not leaked
        note = 'exit=%d expected-warning-found=%s secret-printed=%s' % (
            run.returncode, found, leaked)

    if passed or not keep_failed:
        shutil.rmtree(job_dir, ignore_errors=True)
    else:
        note += ' (kept: %s)' % repo_copy
    return passed, note, time.time() - started


def main():
    parser = argparse.ArgumentParser(description='Run the CI stub suite locally.')
    parser.add_argument('--versions')
    parser.add_argument('--jobs', type=int, default=max(1, min(6, (os.cpu_count() or 2) // 2)))
    parser.add_argument('--only', action='append', default=[])
    parser.add_argument('--keep-failed', action='store_true')
    parser.add_argument('--out')
    args = parser.parse_args()

    ci_versions, jobs = read_ci_jobs()
    versions = args.versions.split(',') if args.versions else ci_versions
    if args.only:
        jobs = [job for job in jobs if any(text in job['name'] for text in args.only)]
        if not jobs:
            sys.exit('No job name contains any of: ' + ', '.join(args.only))
    counts = {kind: sum(1 for job in jobs if job['kind'] == kind)
              for kind in ('positive', 'negative', 'slack')}
    print('CI matrix: Nextflow %s' % ', '.join(ci_versions))
    print('Running %d positive, %d negative and %d Slack jobs on Nextflow %s, %d at a time'
          % (counts['positive'], counts['negative'], counts['slack'], ', '.join(versions),
             args.jobs), flush=True)

    started = time.time()
    rows = []

    quoting = subprocess.run([sys.executable, 'test-resources/check-script-quoting.py'],
                             cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    last_line = quoting.stdout.strip().splitlines()[-1] if quoting.stdout.strip() else ''
    rows.append(('-', 'script-quoting', 'check-script-quoting.py',
                 'PASS' if quoting.returncode == 0 else 'FAIL', last_line, 0.0))
    print('%-8s %-9s %-4s %s  %s' % ('-', 'quoting', rows[-1][3], rows[-1][2], last_line),
          flush=True)

    base_dir = tempfile.mkdtemp(prefix='nf-stub-suite-')

    def record(version, job, result):
        passed, note, seconds = result
        rows.append((version, job['kind'], job['name'], 'PASS' if passed else 'FAIL', note,
                     seconds))
        print('%-8s %-9s %-4s %-48s %5.0fs  %s' % (
            version, job['kind'], rows[-1][3], job['name'], seconds, note), flush=True)

    # The first job of each version runs alone: it downloads that Nextflow version and the
    # plugins if they are not cached yet, which must not happen in several processes at once.
    remaining = []
    for version in versions:
        if jobs:
            record(version, jobs[0], run_job(jobs[0], version, base_dir, args.keep_failed))
        remaining += [(version, job) for job in jobs[1:]]

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_job, job, version, base_dir, args.keep_failed): (version, job)
                   for version, job in remaining}
        for future in concurrent.futures.as_completed(futures):
            version, job = futures[future]
            record(version, job, future.result())

    if not args.keep_failed:
        shutil.rmtree(base_dir, ignore_errors=True)

    if args.out:
        with open(args.out, 'w') as handle:
            for row in rows:
                handle.write('\t'.join(str(field) for field in row[:5]) + '\n')

    failed = [row for row in rows if row[3] != 'PASS']
    print()
    print('%d jobs, %d failed, %.1f minutes' % (len(rows), len(failed),
                                                (time.time() - started) / 60))
    for row in failed:
        print('FAILED: nextflow %s / %s / %s: %s' % (row[0], row[1], row[2], row[4]))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
