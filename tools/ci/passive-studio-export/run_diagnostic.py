#!/usr/bin/env python3
"""One hosted partial diagnostic; no source changes or automatic retries."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

BASE = Path(__file__).resolve().parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--browser', required=True, type=Path)
    parser.add_argument('--node', default=shutil.which('node'), type=Path)
    args = parser.parse_args()
    manifest_path = BASE / 'diagnostic-copy-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    studio = Path(manifest['studioRoot'])
    repository = Path(manifest['repositoryRoot'])
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=studio, text=True).strip()
    assert head == manifest['sourceCommit'] == '1c561d7b91d9b75bd7ba29aa081fcba959089fee', 'Source commit changed'
    for name, digest in manifest['sourceHashes'].items():
        assert sha(studio / name) == digest, f'Shipping Studio input changed: {name}'
    for name, digest in manifest['repositoryHashes'].items():
        assert sha(repository / name) == digest, f'Shipping repository input changed: {name}'
    for name, digest in manifest['diagnosticHashes'].items():
        assert sha(BASE / name) == digest, f'Diagnostic payload changed: {name}'
    subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], cwd=repository, check=True)
    assert args.browser.is_file() and os.access(args.browser, os.X_OK), 'Explicit browser is unavailable'
    assert args.node and args.node.is_file() and os.access(args.node, os.X_OK), 'Explicit Node is unavailable'
    run_dir = BASE / 'run-1'
    run_dir.mkdir(mode=0o700)  # Exclusive latch. An existing run is never retried.
    artifacts = run_dir / 'artifacts'
    artifacts.mkdir(mode=0o700)
    journal_path = run_dir / 'journal.json'
    journal = {'schema': 'rendprop-one-hosted-passive-diagnostic-v1', 'startedAtUTC': utc(),
        'sourceCommit': head, 'manifestSha256': sha(manifest_path), 'runtimeVersions': {},
        'partialSuite': True, 'audioOutputMode': 'default-device', 'attemptsAuthorized': 1,
        'scope': 'First narrated export, unchanged shipping quality/output assertions. Not a required CI gate or full-suite pass. No live accounts/provider jobs.',
        'status': 'preflight', 'artifacts': str(artifacts)}
    def save():
        journal_path.write_text(json.dumps(journal, indent=2) + '\n')
        journal_path.chmod(0o600)
    save()
    effective_exit = 1
    try:
        commands = [('node', [str(args.node), '--version']), ('browser', [str(args.browser), '--version']),
            ('ffmpeg', ['ffmpeg', '-version']), ('ffprobe', ['ffprobe', '-version'])]
        journal['runtimeVersionsRaw'] = {}
        for label, command in commands:
            raw_version = subprocess.check_output(command,
                text=True, stderr=subprocess.STDOUT).splitlines()[0]
            journal['runtimeVersionsRaw'][label] = raw_version
            journal['runtimeVersions'][label] = raw_version.strip()
        versions = journal['runtimeVersions']
        assert versions['node'] == 'v24.22.2', 'Node differs from failed hosted condition'
        assert versions['browser'] == 'Google Chrome for Testing 153.0.8010.12', 'Browser version differs'
        assert versions['ffmpeg'].startswith('ffmpeg version 9.0.2 '), 'FFmpeg version differs'
        assert versions['ffprobe'].startswith('ffprobe version 9.0.2 '), 'FFprobe version differs'
        journal['status'] = 'running'
        save()
        env = dict(os.environ, STUDIO_BROWSER_EXECUTABLE=str(args.browser), TMPDIR=str(artifacts))
        # No silent-audio option. Failed CI used the native default output.
        with (run_dir / 'run.log').open('w') as log:
            result = subprocess.run([str(args.node), manifest['harness']], cwd=studio,
                env=env, stdout=log, stderr=subprocess.STDOUT, check=False)
        journal['childExitCode'] = result.returncode
        studio_unchanged = {name: sha(studio / name) == digest for name, digest in manifest['sourceHashes'].items()}
        repository_unchanged = {name: sha(repository / name) == digest for name, digest in manifest['repositoryHashes'].items()}
        payload_unchanged = {name: sha(BASE / name) == digest for name, digest in manifest['diagnosticHashes'].items()}
        journal.update(sourceHashesStillMatch=studio_unchanged, repositoryHashesStillMatch=repository_unchanged,
            diagnosticHashesStillMatch=payload_unchanged)
        assert all(studio_unchanged.values()) and all(repository_unchanged.values()) and all(payload_unchanged.values()), 'Pinned inputs changed'
        receipts = list(artifacts.glob('rendprop-cloud-editor-*/receipt.json'))
        assert len(receipts) == 1, 'Expected one partial browser diagnostic receipt'
        receipt = json.loads(receipts[0].read_text())
        journal.update(receipt=str(receipts[0]), receiptSha256=sha(receipts[0]), receiptStatus=receipt['status'])
        assert receipt['partialSuite'] is True and receipt['sourceBoundAtEnd'] is True, 'Partial source binding missing'
        assert receipt['audioOutput']['mode'] == 'default-device', 'Audio output changed'
        assert receipt['externalRequests'] == [], 'Unexpected external request'
        if result.returncode == 0:
            assert receipt['status'] == 'diagnostic-case-passed' and receipt['diagnosticCaseStatus'] == 'passed', 'Unexpected success claim'
            captures = [device['passiveCapture'] for device in receipt['mediaTiming'] if device.get('passiveCapture', {}).get('sessions')]
            assert len(captures) == 1 and captures[0]['nativeHook']['installed'] is True, 'Native hook not observed'
            assert len(captures[0]['sessions']) == 1, 'Expected one export only'
            session = captures[0]['sessions'][0]
            assert session['requests'] and session['encoded'] and 'refusal' not in session['encoded'], 'Incomplete successful evidence'
            effective_exit = 0
            journal['status'] = 'diagnostic-case-passed'
        else:
            journal['status'] = 'diagnostic-case-failed'
    except Exception as error:
        journal.update(status='diagnostic-error', errorClass=type(error).__name__, error=str(error)[:500])
    finally:
        journal.update(exitCode=effective_exit, finishedAtUTC=utc())
        save()
    print(json.dumps({'exitCode': effective_exit, 'status': journal['status'],
        'journal': str(journal_path), 'runLog': str(run_dir / 'run.log')}))
    raise SystemExit(effective_exit)

if __name__ == '__main__':
    main()
