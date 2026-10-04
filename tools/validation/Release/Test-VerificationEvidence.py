import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--pwsh', required=True)
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
runner = Path(__file__).with_name('Invoke-IntegrationVerification.ps1')
args.out.mkdir(parents=True, exist_ok=True)
cases = {
    'complete': ('2026-10-01T00:00:00Z PASS setup-fallbacks exit 0\n', 0),
    'missing': (None, 1),
    'empty': ('', 1),
    'missing-required': ('2026-10-01T00:00:00Z PASS unrelated check\n', 1),
    'failure': ('2026-10-01T00:00:00Z PASS setup-fallbacks exit 0\n2026-10-01T00:00:01Z FAIL exact adverse state\n', 1),
    'skipped': ('2026-10-01T00:00:00Z PASS setup-fallbacks exit 0\n2026-10-01T00:00:01Z SKIPPED required probe\n', 1),
    'not-run': ('2026-10-01T00:00:00Z PASS setup-fallbacks exit 0\n2026-10-01T00:00:01Z NOT RUN required probe\n', 1),
    'fatal-after-pass': ('2026-10-01T00:00:00Z PASS setup-fallbacks exit 0\n2026-10-01T00:00:01Z FATAL System.IO.IOException\n', 1),
}
failures = []
with tempfile.TemporaryDirectory(prefix='roo-verification-evidence-') as scratch:
    env = os.environ | {name: scratch for name in ('TEMP', 'USERPROFILE', 'ProgramFiles')}
    for name, (content, expected) in cases.items():
        evidence = Path(scratch) / name
        evidence.mkdir()
        if content is not None:
            (evidence / 'setup-fallbacks.log').write_text(content)
        result = subprocess.run([args.pwsh, '-NoProfile', '-File', str(runner), '-Phase', 'summary', '-Evidence', str(evidence), '-Expect', 'setup-fallbacks'], env=env, text=True, capture_output=True)
        (args.out / (name + '.txt')).write_text(result.stdout + result.stderr)
        passed = result.returncode == expected
        print(f'{"PASS" if passed else "FAIL"} {name}: exit={result.returncode} expected={expected}')
        if not passed:
            failures.append(name)
    baseline = {'backupFormat': 2, 'appFolder': False, 'uninstallEntries': [], 'localSiblings': [], 'tasks': [], 'productKeys': [], 'enableTransparency': '<absent>', 'ifeoProbeKey': False, 'downloadBlockerFolder': False, 'userEnvironmentNames': [], 'tweakStateKey': '<absent>', 'rooHklmFingerprint': '<absent>', 'hypervisorlaunchtype': '', 'vbsStatus': '', 'vbsRunning': '', 'rebootPendingCbs': False, 'rebootRequiredUpdate': False, 'pendingFileRenames': ''}
    for name, state in [('missing-baseline', None), ('historical-baseline', baseline | {'backupFormat': 1}), ('foreign-installation', baseline | {'appFolder': True, 'uninstallEntries': ['existing_is1']}), ('incomplete-baseline', {'backupFormat': 2}), ('missing-original-backup', baseline | {'localSiblings': ['RooIndustriesOptimizationSuite']})]:
        evidence = Path(scratch) / name
        backup = Path(scratch) / (name + '-backup')
        backup.mkdir()
        if state is not None:
            (backup / 'machine-state.json').write_text(json.dumps(state))
        sentinel = backup / 'keep-original.txt'
        sentinel.write_text('original bytes')
        result = subprocess.run([args.pwsh, '-NoProfile', '-File', str(runner), '-Phase', 'cleanup', '-Evidence', str(evidence), '-BackupRoot', str(backup)], env=env, text=True, capture_output=True)
        (args.out / (name + '.txt')).write_text(result.stdout + result.stderr)
        passed = result.returncode == 1 and sentinel.read_text() == 'original bytes' and 'FAIL unhandled exception' in result.stdout
        print(f'{"PASS" if passed else "FAIL"} {name}: exit={result.returncode} original preserved={sentinel.exists()}')
        if not passed:
            failures.append(name)
    driver = runner.with_name('Run-FinalVerification.sh')
    for name, command, expected, extra in [('transport-failure', ['phase', 'summary'], 1, {'PY': '/bin/false'}), ('unknown-start-phase', ['all'], 2, {'FROM': 'unknown'})]:
        result = subprocess.run(['bash', str(driver), *command], env=env | extra | {'OUT': str(Path(scratch) / name)}, text=True, capture_output=True)
        (args.out / (name + '.txt')).write_text(result.stdout + result.stderr)
        passed = result.returncode == expected
        print(f'{"PASS" if passed else "FAIL"} {name}: exit={result.returncode} expected={expected}')
        if not passed:
            failures.append(name)
raise SystemExit(bool(failures))
