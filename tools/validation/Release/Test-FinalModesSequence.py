from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--case', choices=('all', 'release-pass-counters', 'timestamped-failure'), default='all')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[3]
    adapter = args.out / 'python-adapter'
    adapter.write_text('#!' + sys.executable + '\n' + r'''
import json, os, pathlib, subprocess, sys
if len(sys.argv) < 2 or pathlib.Path(sys.argv[1]).name != 'windows_ssh.py':
    sys.exit(subprocess.call([sys.executable, *sys.argv[1:]]))
argv=sys.argv[2:]
def field(name): return argv[argv.index(name)+1]
if field('--host') != 'fixture-only' or field('--expected-machine') != 'FIXTURE-ONLY':
    raise SystemExit('Unexpected transport target')
script=field('--script'); values=json.loads(field('--arguments'))
trace=pathlib.Path(os.environ['MODES_TRACE'])
with trace.open('a') as stream: stream.write(json.dumps({'script':script,'arguments':values})+'\n')
state_file=pathlib.Path(os.environ['MODES_STATE'])
state=json.loads(state_file.read_text())
status=0
if script not in ('tools\\scripts\\Build-Release.ps1','tools\\validation\\Release\\Invoke-IntegrationVerification.ps1'):
    print('FAIL unexpected source script '+script);sys.exit(1)
if values.get('Phase') == 'release-build':
    if os.environ['MODES_CASE'] == 'release-pass-counters':
        print('2026-10-05T00:35:56.8511127Z PASS build-release exit 0 in 122 s; PASS lines 2, FAIL lines 0, SKIP lines 0; last line: {')
    elif os.environ['MODES_CASE'] == 'timestamped-failure':
        print('2026-10-05T00:35:56.8511127Z FAIL the release build produced a production installer :: missing')
elif script.endswith('Build-Release.ps1'):
    if values.get('TestHooks') is not True or values.get('OutputRoot') == os.environ['MODES_PRODUCTION_ROOT']:
        print('FAIL hook build is not isolated');status=1
    elif os.environ['MODES_CASE'] == 'build-failure':
        print('FAIL test build failed');status=1
    else: state['hookRoot']=values['OutputRoot']
elif values.get('Phase') == 'install-other':
    installer=values['OtherInstaller']
    if state.get('hookRoot') and installer.startswith(state['hookRoot']+'\\'):
        state['installed']='hooks'
    elif installer == os.environ['MODES_PRODUCTION_INSTALLER']:
        state['installed']='production'
    else:
        print('FAIL unknown installer');status=1
elif values.get('Phase') == 'scenario' and values.get('Scenario') == 'modes':
    if state['installed'] != 'hooks':
        print('NOT RUN the feature hang check requires the test hook');status=1
    elif os.environ['MODES_CASE'] == 'modes-failure':
        print('FAIL feature journey');status=1
elif values.get('Phase') == 'scenario' and values.get('Scenario') == 'loadtimes':
    if state['installed'] != 'production':
        print('FAIL load times measured a test build');status=1
state_file.write_text(json.dumps(state))
if status == 0: print('PASS isolated transport contract')
sys.exit(status)
''')
    adapter.chmod(0o700)
    results = []
    exact_paths = True
    cases = ('success', 'modes-failure', 'build-failure', 'release-pass-counters', 'timestamped-failure') if args.case == 'all' else (args.case,)
    for name in cases:
        directory = args.out / name
        directory.mkdir()
        frame = 'C:\\RooFixture\\roo-industries-final-run-' + uuid.uuid4().hex
        production_root = frame + '\\release'
        production_installer = production_root + '\\RooIndustries-OptimizationSuite-0.10.0-beta-setup.exe'
        (directory / 'stage.json').write_text(json.dumps({
            'machine': 'FIXTURE-ONLY', 'stagingPath': frame + '\\source',
            'runRoot': frame, 'manifestSha256': '0' * 64,
            'frameId': frame.rsplit('-', 1)[1],
        }))
        state_file = directory / 'state.json'
        state_file.write_text(json.dumps({'installed': 'production'}))
        trace = directory / 'trace.jsonl'
        environment = dict(os.environ, HOST='fixture-only', MACHINE='FIXTURE-ONLY',
                           OUT=str(directory.resolve()), PY=str(adapter.resolve()),
                           OLD_INSTALLER='C:\\retained\\RooIndustries-OptimizationSuite-0.9.0-beta-setup.exe',
                           NEW_INSTALLER=production_installer, FROM='modes',
                           MODES_CASE=name, MODES_STATE=str(state_file.resolve()),
                           MODES_TRACE=str(trace.resolve()), MODES_PRODUCTION_ROOT=production_root,
                           MODES_PRODUCTION_INSTALLER=production_installer)
        environment.pop('SKIP', None)
        command = ['phase', 'release-build', '-BuildOutput', production_root] if name in ('release-pass-counters', 'timestamped-failure') else ['all']
        result = subprocess.run(['bash', str(root / 'tools/validation/Release/Run-FinalVerification.sh'), *command],
                                env=environment, capture_output=True, text=True)
        (directory / 'driver.log').write_text(result.stdout + result.stderr)
        calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
        exact_paths = exact_paths and bool(calls) and all(row['script'] in ('tools\\scripts\\Build-Release.ps1', 'tools\\validation\\Release\\Invoke-IntegrationVerification.ps1') for row in calls)
        state = json.loads(state_file.read_text())
        if name in ('release-pass-counters', 'timestamped-failure'):
            passed = len(calls) == 1 and (result.returncode == 0) == (name == 'release-pass-counters')
            results.append({'name': name, 'passed': passed, 'exit': result.returncode})
            continue
        builds = [row for row in calls if row['script'].endswith('Build-Release.ps1')]
        installs = [row for row in calls if row['arguments'].get('Phase') == 'install-other']
        modes = [row for row in calls if row['arguments'].get('Scenario') == 'modes']
        passed = len(builds) == 1 and state['installed'] == 'production'
        if name == 'build-failure':
            passed = passed and result.returncode != 0 and not installs and not modes
        else:
            passed = passed and len(installs) == 2 and len(modes) == 1
            passed = passed and (result.returncode == 0) == (name == 'success')
            if len(installs) == 2 and modes:
                passed = passed and calls.index(builds[0]) < calls.index(installs[0]) < calls.index(modes[0]) < calls.index(installs[1])
                passed = passed and installs[1]['arguments']['OtherInstaller'] == production_installer
        results.append({'name': name, 'passed': bool(passed), 'exit': result.returncode, 'installed': state['installed']})
    results.append({'name': 'exact-script-paths', 'passed': exact_paths})
    (args.out / 'checks.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
    return int(any(not row['passed'] for row in results))


if __name__ == '__main__':
    raise SystemExit(main())
