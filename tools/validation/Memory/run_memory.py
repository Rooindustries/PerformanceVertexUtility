import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[3]
MIB = 1048576


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def identity(path):
    with path.open('rb') as stream:
        return {'bytes': path.stat().st_size, 'sha256': hashlib.file_digest(stream, 'sha256').hexdigest()}


def describe_error(error):
    if isinstance(error, subprocess.CalledProcessError):
        detail = (error.stderr or error.stdout or str(error)).strip()
        return type(error).__name__ + ': ' + detail[-2048:]
    return type(error).__name__ + ': ' + str(error)


def same_registry(before, after):
    def index(rows):
        return {(r['hive'], r['path']): (r['exists'], {v['name']: (v['kind'], v['rawBase64']) for v in r['values']}) for r in rows}
    return index(before) == index(after)


def cleanup_checks(before, after, frame):
    files = lambda roots: {f['path']: f['sha256'] for r in roots for f in r['files']}
    tasks = lambda rows: {t['path'] + t['name']: t for t in rows}
    old_tasks, new_tasks = tasks(before['tasks']), tasks(after['tasks'])
    cs2 = [t for t in before['tasks'] if 'CS2' in t['name']]
    old_frames = {f['path']: f['creationTimeFileTimeUtc'] for f in before['frames'] if f['path'] != frame['runRoot']}
    new_frames = {f['path']: f['creationTimeFileTimeUtc'] for f in after['frames']}
    payload = lambda snapshot: {f['path']: f['sha256'] for f in snapshot['payload']}
    return {
        'installedVersionRestored': after['installedVersion'] == before['installedVersion'],
        'installedPayloadRestored': payload(before) == payload(after),
        'dataByteIdentical': files(before['dataRoots']) == files(after['dataRoots']),
        'dataRootPresenceRestored': {r['path']: r['exists'] for r in before['dataRoots']} == {r['path']: r['exists'] for r in after['dataRoots']},
        'rawRegistryByteIdentical': same_registry(before['rawRegistry'], after['rawRegistry']),
        'scheduledTasksRestored': old_tasks.keys() == new_tasks.keys() and all(old_tasks[k]['xml'] == new_tasks[k]['xml'] and old_tasks[k]['enabled'] == new_tasks[k]['enabled'] for k in old_tasks),
        'CS2TasksUnchanged': all(t['path'] + t['name'] in new_tasks and new_tasks[t['path'] + t['name']]['state'] == t['state'] and new_tasks[t['path'] + t['name']]['enabled'] == t['enabled'] for t in cs2),
        'legacyFramesUnchanged': old_frames == new_frames,
        'noOwnedFrame': not any(f['path'] == frame['runRoot'] for f in after['frames']),
        'zeroRooOrFrameProcesses': not after['processes'],
        'leaseAbsent': not after['lease'],
        'hostsByteIdentical': before['hostsBase64'] == after['hostsBase64'],
        'firewallUnchanged': before['firewall'] == after['firewall'],
        'testCertificatesUnchanged': before['certificates'] == after['certificates'],
    }


def gate(summary, logs):
    checks = []
    comparison = summary.get('comparison')
    if not comparison:
        return [{'check': 'measurements verified', 'passed': summary['status'] == 'verified'}]
    for point, maximum, description in [
        ('final-Home-60s', -30 * MIB, 'at least 30 MiB below control'),
        ('post-reopen-Home-15s', 15 * MIB, 'no more than 15 MiB above control'),
        ('minimized-60s', 2 * MIB, 'no more than 2 MiB above control'),
    ]:
        row = next(p for p in comparison['differences'] if p['point'] == point)
        value = row['privateWorkingSetBytes']['all']
        checks.append({'check': point, 'observedDifferenceBytes': value, 'maximumDifferenceBytes': maximum,
                       'rule': description, 'passed': value is not None and value <= maximum})
    control = comparison.get('reopen', [])
    for measured in summary['reopen']:
        old = next((r for r in control if r['page'] == measured['page']), None)
        difference = measured['allMedianMs'] - old['allMedianMs'] if old else None
        checks.append({'check': 'reopen ' + measured['page'], 'observedDifferenceMs': difference,
                       'maximumDifferenceMs': 50, 'passed': difference is not None and difference <= 50})
    failures = sum(text.count('Freeing memory failed') for text in logs)
    checks.append({'check': 'memory relief failure logs', 'observed': failures, 'passed': failures == 0})
    checks.append({'check': 'foreground success logging removed', 'observed': sum(t.count('Foreground relief:') for t in logs),
                   'passed': not any('Foreground relief:' in t for t in logs)})
    return checks


class Measurement:
    def __init__(self, args):
        self.args = args
        self.windows = load('memory_windows', ROOT / 'tools/validation/windows_ssh.py')
        self.frame = None
        self.before = None
        self.modified_install = False
        self.archives = {}
        self.out = args.out_dir

    def scope(self):
        w, f = self.windows, self.frame
        return w.harness_tree_helpers() + '\n. (Get-HarnessToolPath ' + w.ps_literal(f['stagingPath'] + '/tools/validation/Memory/Memory.Common.ps1') + ');Open-HarnessRun ' + ' '.join(w.ps_literal(f[k]) for k in ['runRoot', 'frameId', 'manifestSha256']) + ' ' + w.ps_literal(f['frameId']) + ';Assert-HarnessHostLease;'

    def invoke(self, code, timeout=None):
        return self.windows.invoke(self.args.host, self.args.expected_machine, code, timeout=timeout or self.windows.EVIDENCE_TIMEOUT)

    def download(self, remote, local, expected=None):
        self.windows.run_transport(self.args.host, 'scp', [self.args.host + ':' + remote.replace('\\', '/'), str(local)],
                                   timeout=self.windows.TRANSFER_TIMEOUT, capture_output=True, text=True)
        if expected and identity(local)['sha256'].upper() != expected.upper():
            raise ValueError('Downloaded evidence hash differs: ' + str(local))

    def input(self, local, name):
        w, f = self.windows, self.frame
        directory = f['runRoot'] + '\\inputs'
        remote = directory + '\\' + name
        self.invoke(self.scope() + 'if(-not(Test-HarnessPath ' + w.ps_literal(directory) + ')){New-HarnessDirectory ' + w.ps_literal(directory) + " 'memory-inputs'|Out-Null};if(Test-HarnessPath " + w.ps_literal(remote) + "){throw 'Input exists; retained'}")
        w.run_transport(self.args.host, 'scp', [str(local), self.args.host + ':' + remote.replace('\\', '/')],
                        timeout=w.TRANSFER_TIMEOUT, capture_output=True, text=True)
        self.invoke(self.scope() + 'Register-HarnessFile ' + w.ps_literal(remote) + " 'memory-input'|Out-Null;if((Get-HarnessFileSha256 " + w.ps_literal(remote) + ') -cne ' + w.ps_literal(identity(local)['sha256'].upper()) + "){throw 'Input identity differs'}")
        return remote

    def desktop(self, name, fields, minutes):
        w = self.windows
        result = w.interactive_frame(self.args.host, self.args.expected_machine, self.frame,
                                     'tools/validation/Memory/' + name + '.ps1', fields, minutes)
        (self.out / (name + '.log')).write_text(result.stdout)
        completion = w.completion(result.stdout)
        save(self.out / (name + '-completion.json'), completion)
        if not completion['passed']:
            raise RuntimeError(name + ' did not complete')
        return completion, w.read_result(self.args.host, self.args.expected_machine, self.frame, 'receipt.json', completion['nonce'])

    def snapshot(self, name):
        w, f = self.windows, self.frame
        directory = f['runRoot'] + '\\snapshots'
        result = self.invoke(self.scope() + 'if(-not(Test-HarnessPath ' + w.ps_literal(directory) + ')){New-HarnessDirectory ' + w.ps_literal(directory) + " 'memory-snapshots'|Out-Null};$path=Write-HarnessResult " + w.ps_literal(directory) + ' ' + w.ps_literal(name + '.json') + ' (Get-MemorySnapshot);@{path=$path;sha256=Get-HarnessFileSha256 $path}|ConvertTo-Json')
        info = json.loads(result.stdout)
        path = self.out / (name + '.json')
        self.download(info['path'], path, info['sha256'])
        value = json.loads(path.read_text(encoding='utf-8-sig'))
        if value['nonce'] != f['frameId']:
            raise ValueError('Snapshot nonce differs')
        return value['data']

    def preflight(self):
        self.before = self.snapshot('as-found')
        before = self.before
        if not before['installedVersion'] or before['processes']:
            raise RuntimeError('An installed, stopped Suite is required; close the app and pause the governor first.')
        if any(t['enabled'] for t in before['tasks'] if '.ProcessRules.' in t['name']):
            raise RuntimeError('Pause saved process rules before measuring; their as-found state is preserved.')
        w, f = self.windows, self.frame
        result = self.invoke(self.scope() + '$installer=' + w.ps_literal(self.restore_remote) + ';@{version=(Get-HarnessItem $installer).VersionInfo.ProductVersion.TrimEnd(" ");sha256=Get-HarnessFileSha256 $installer}|ConvertTo-Json')
        restored = json.loads(result.stdout)
        if restored['version'] != before['installedVersion']:
            raise ValueError('Restore installer version differs from the as-found installation')
        for i, root in enumerate(before['dataRoots']):
            if not root['exists']:
                continue
            path = f['runRoot'] + '\\data-before-' + str(i) + '.zip'
            result = self.invoke(self.scope() + 'New-HarnessArchive ' + w.ps_literal(root['path']) + ' ' + w.ps_literal(path) + ' {param($item,$relative) $true}|Out-Null;Get-HarnessFileSha256 ' + w.ps_literal(path))
            self.download(path, self.out / ('data-before-' + str(i) + '.zip'), result.stdout.strip())
            self.archives[root['path']] = path

    def collect(self):
        w, f = self.windows, self.frame
        path = f['runRoot'] + '\\evidence.zip'
        self.invoke(self.scope() + 'New-HarnessArchive ' + w.ps_literal(f['runRoot']) + ' ' + w.ps_literal(path) + " {param($item,$relative) $relative=$relative.Replace('\\','/');$relative -notmatch '^(Source|source|inputs|b/release|b/heap|b/probe)/' -and $relative -ne 'evidence.zip'}|Out-Null")
        local = self.out / 'evidence.zip'
        self.download(path, local)
        with zipfile.ZipFile(local) as archive:
            for name in archive.namelist():
                w.safe_archive_path(name)
            archive.extractall(self.out / 'evidence')

    def restore(self):
        w, f = self.windows, self.frame
        self.invoke(self.scope() + "$entries=@(Get-HarnessEntries|Where-Object {$_.kind -in 'process','window' -and $_.state -eq 'active' -and $_.lifetime -ne 'runner'});[array]::Reverse($entries);foreach($entry in $entries){Remove-HarnessEntry $entry}", timeout=w.CLEANUP_TIMEOUT)
        fields = {'Source': f['stagingPath'], 'OutRoot': f['runRoot'] + '\\restore', 'Installer': self.restore_remote,
                  'ExpectedVersion': self.before['installedVersion'], 'Sha256': self.args.restore_sha256.upper()}
        self.desktop('Install-MemoryBuild', fields, 10)
        current = self.snapshot('before-data-restore')
        bundle = self.out / 'restore-input.json'
        save(bundle, {'before': self.before, 'current': current, 'archives': self.archives})
        remote = self.input(bundle, 'restore.json')
        result = self.invoke(self.scope() + '$input=Read-HarnessInputText ' + w.ps_literal(remote) + '|ConvertFrom-Json;$data=@(Restore-MemoryData $input.before $input.current $input.archives);$registry=@(Restore-MemoryRegistry $input.before.rawRegistry $input.current.rawRegistry);@{data=$data;registry=$registry}|ConvertTo-Json -Depth 12')
        (self.out / 'restore-receipt.json').write_text(result.stdout)

    def clear(self):
        w, f = self.windows, self.frame
        result = self.invoke('& ' + w.ps_literal(f['stagingPath'] + '/tools/validation/Update/Clear-UpdateFrame.ps1') + ' -Frame ' + w.ps_literal(f['runRoot']) + ' -ExpectedMachine ' + w.ps_literal(self.args.expected_machine), timeout=w.CLEANUP_TIMEOUT)
        (self.out / 'closed-ledger.json').write_text(result.stdout)
        ledger = json.loads(result.stdout)
        if any(e['state'] in ['active', 'error'] for e in ledger['entries']) or any(i['status'] == 'running' for i in ledger['invocations']):
            raise RuntimeError('Creation ledger did not close')

    def final_snapshot(self):
        w = self.windows
        common = (ROOT / 'tools/validation/Memory/Memory.Common.ps1').read_text().splitlines()
        script = w.harness_tree_helpers() + '\n' + (ROOT / 'backend/scripts/BrandCompatibility.Common.ps1').read_text(encoding='utf-8-sig') + '\n' + '\n'.join(common[2:]) + '\nGet-MemorySnapshot|ConvertTo-Json -Depth 20'
        result = self.invoke(script)
        (self.out / 'final-inventory.json').write_text(result.stdout)
        return json.loads(result.stdout)

    def run(self):
        w = self.windows
        checks, errors = [], []
        restored = True
        result = {'status': 'fail', 'checks': checks, 'cleanupErrors': errors, 'completedInstallerDownloads': 0}
        try:
            self.frame = w.upload_frame(self.args.host, self.args.expected_machine, 'roo-industries-m', True, r'C:\RooBuild')
            save(self.out / 'frame.json', self.frame)
            w.enter_host_lease(self.args.host, self.args.expected_machine, self.frame)
            w.verify_local_source(self.args.host, self.args.expected_machine, self.frame)
            self.restore_remote = self.input(self.args.restore_installer, 'restore.exe')
            self.preflight()
            parse = self.invoke(self.scope() + '$rows=@();foreach($file in Get-HarnessTree ' + w.ps_literal(self.frame['stagingPath'] + '/tools/validation/Memory') + " -FilesOnly|Where-Object {[IO.Path]::GetExtension($_.FullName) -ieq '.ps1'}){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($file.LongPath),[ref]$tokens,[ref]$errors)|Out-Null;$rows+=@{path=$file.FullName;errors=@($errors|ForEach-Object {$_.Message})}};@{powershell=$PSVersionTable.PSVersion.ToString();files=$rows}|ConvertTo-Json -Depth 10")
            (self.out / 'parse.json').write_text(parse.stdout)
            parsed = json.loads(parse.stdout)
            if any(r['errors'] for r in parsed['files']):
                raise ValueError('PowerShell parse failed')
            checks.append({'check': 'PS 5.1 parse', 'observed': parsed['powershell'], 'passed': parsed['powershell'].startswith('5.1.')})
            fields = {'Source': self.frame['stagingPath'], 'OutRoot': self.frame['runRoot'] + '\\b'}
            if self.args.heap_probe:
                fields['HeapProbe'] = True
            _, build = self.desktop('Build-Memory', fields, 20)
            save(self.out / 'build-receipt.json', build)
            if build['feed'] != 'url=':
                raise ValueError('Updates are not disabled')
            self.download(build['installer'], self.out / 'installer.exe', build['sha256'])
            self.modified_install = True
            self.desktop('Install-MemoryBuild', {'Source': self.frame['stagingPath'], 'OutRoot': self.frame['runRoot'] + '\\install',
                                                'Installer': build['installer'], 'ExpectedVersion': build['version'], 'Sha256': build['sha256']}, 10)
            print('PASS build/install; measuring ' + str(self.args.runs) + ' lifetimes', flush=True)
            completion, receipt = self.desktop('Measure-Memory', {'Source': self.frame['stagingPath'], 'OutRoot': self.frame['runRoot'] + '\\m',
                                                                 'Runs': self.args.runs, 'Analyzer': build['heap']}, self.args.runs * 9 + 5)
            save(self.out / 'measurement-completion.json', completion)
            save(self.out / 'measurement-receipt.json', receipt)
            for name, info in receipt['files'].items():
                if Path(name).name != name:
                    raise ValueError('Evidence name is not a leaf')
                self.download(info['path'], self.out / name, info['sha256'])
                if info['format'] == 'json' and json.loads((self.out / name).read_text(encoding='utf-8-sig'))['nonce'] != completion['nonce']:
                    raise ValueError('Evidence invocation nonce differs')
            summarize = load('memory_summary', ROOT / 'tools/validation/Memory/Summarize-Memory.py')
            summary = summarize.summarize(self.out, self.args.compare)
            logs = [(self.out / ('app-log-run' + str(run) + '.txt')).read_text() for run in range(1, self.args.runs + 1)]
            checks.extend(gate(summary, logs))
            result['status'] = 'pass' if all(c['passed'] for c in checks) else 'fail'
        except BaseException as error:
            result['failure'] = describe_error(error)
            if isinstance(error, subprocess.CalledProcessError):
                (self.out / 'failure.log').write_text((error.stdout or '') + (error.stderr or ''))
        finally:
            if self.frame:
                if self.modified_install and self.before:
                    try:
                        self.restore()
                    except BaseException as error:
                        restored = False
                        errors.append('Restore: ' + describe_error(error))
                try:
                    self.collect()
                except BaseException as error:
                    errors.append('Evidence: ' + describe_error(error))
                if restored:
                    try:
                        self.clear()
                    except BaseException as error:
                        errors.append('Frame cleanup: ' + describe_error(error))
                else:
                    result['retainedFrame'] = self.frame['runRoot']
                if self.before:
                    try:
                        after = self.final_snapshot()
                        audit = cleanup_checks(self.before, after, self.frame)
                        save(self.out / 'cleanup-audit.json', {'status': 'pass' if all(audit.values()) else 'fail', 'checks': audit})
                        checks.extend({'check': name, 'passed': passed} for name, passed in audit.items())
                    except BaseException as error:
                        errors.append('Audit: ' + describe_error(error))
            if errors or not checks or not all(c['passed'] for c in checks):
                result['status'] = 'fail'
            save(self.out / 'receipt.json', result)
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scenario', choices=['baseline'], required=True)
    parser.add_argument('--host', required=True)
    parser.add_argument('--expected-machine', required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--compare', type=Path)
    parser.add_argument('--heap-probe', action='store_true')
    parser.add_argument('--restore-installer', type=Path, required=True)
    parser.add_argument('--restore-sha256', required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.runs <= 10:
        parser.error('--runs must be between 1 and 10')
    if identity(args.restore_installer)['sha256'].lower() != args.restore_sha256.lower():
        parser.error('Restore installer SHA-256 differs; no remote work started')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip():
        parser.error('Commit the source first; stage a clean branch head')
    lint = load('memory_lint', ROOT / 'tools/validation/Update/run_harness_checks.py')
    lint.lint_tree(ROOT / 'tools/validation/Update')
    args.out_dir.mkdir(parents=True, exist_ok=False)
    source = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'branch': subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip(),
              'restoreInstaller': identity(args.restore_installer), 'runs': args.runs, 'scenario': args.scenario}
    if args.compare:
        source['control'] = {str(p): identity(p) for p in [args.compare, args.compare.parent / 'post-reopen-memory.csv', args.compare.parent / 'reopen.csv'] if p.is_file()}
    save(args.out_dir / 'source-binding.json', source)
    result = Measurement(args).run()
    print(json.dumps(result, indent=2))
    if result['status'] != 'pass':
        raise SystemExit(1)


if __name__ == '__main__':
    main()
