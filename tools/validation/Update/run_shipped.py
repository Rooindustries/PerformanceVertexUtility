import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from urllib.request import Request, urlopen
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
EMPTY = hashlib.sha256(b'').hexdigest()


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


windows = module('shipped_windows', ROOT / 'tools/validation/windows_ssh.py')
release_tool = module('shipped_release', ROOT / 'tools/release/publish_update.py')


ALL_SCENARIOS = ['seed', 'manual-install', 'feed-down', 'slow-feed', 'malformed-feed', 'bad-signature', 'wrong-product', 'wrong-channel', 'same-version', 'older-version', 'tampered', 'tampered-size', 'manual-download', 'ready', 'scheduled-download', 'blocked', 'cancel', 'install', 'failure', 'copy-failure', 'cleanup']


def required_passes(rows, required, frame_id=None):
    if frame_id is not None and any(row.get("frameId") != frame_id for row in rows):
        return False
    return all(any(row['check'] == name and row['status'] == 'pass' for row in rows) for name in required) and not any(row['status'] == 'fail' for row in rows)


class Journey:
    def __init__(self, args):
        self.args = args
        self.out = args.out_dir.resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.frames = {}
        self.feed = (ROOT / 'tools/release/update-feed.txt').read_text().strip()

    def save(self, path, value):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2))

    def command(self, values, log=None, host=None):
        started = time.monotonic()
        argv = [str(v) for v in values]
        try:
            result = (windows.run_transport(host, argv[0], argv[1:], timeout=windows.TRANSFER_TIMEOUT,
                      cwd=ROOT, capture_output=True, text=True) if argv[0] in ('ssh', 'scp') else
                      subprocess.run(argv, cwd=ROOT, capture_output=True, text=True))
        except subprocess.CalledProcessError as error:
            output = (error.stdout or '') + (error.stderr or '')
            if log:
                Path(log).parent.mkdir(parents=True, exist_ok=True)
                Path(log).write_text(output)
            raise RuntimeError('Network command failed: ' + output) from None
        if log:
            Path(log).parent.mkdir(parents=True, exist_ok=True)
            Path(log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f'Command failed ({result.returncode}); evidence: {log}\n' + (result.stdout + result.stderr)[-2400:])
        return result.stdout, time.monotonic() - started

    def remote(self, host, machine, script, log, timeout=windows.COMMAND_TIMEOUT):
        try:
            result = windows.invoke(host, machine, script, timeout=timeout)
        except subprocess.CalledProcessError as error:
            Path(log).parent.mkdir(parents=True, exist_ok=True)
            Path(log).write_text((error.stdout or '') + (error.stderr or ''))
            if isinstance(error, (windows.HostUnreachable, windows.RemoteTimeout)):
                raise
            raise RuntimeError(f'Windows command failed; evidence: {log}') from None
        Path(log).parent.mkdir(parents=True, exist_ok=True)
        Path(log).write_text(result.stdout)
        return result.stdout

    def desktop(self, host, machine, receipt, script, fields, label, minutes=20):
        log = self.out / label / 'desktop.log'
        log.parent.mkdir(parents=True, exist_ok=True)
        self.save(log.with_suffix('.command.json'), {'script': script, 'arguments': fields, 'minutes': minutes, 'machine': machine})
        started = time.monotonic()
        try:
            result = windows.interactive_frame(host, machine, receipt, script, fields, minutes, 'RooIndustries_ROO29_' + label.replace('/', '_').replace('-', '_'))
            log.write_text(result.stdout)
            completion = windows.completion(result.stdout)
            return {'status': 'pass' if completion['passed'] else 'fail', 'nonce': completion['nonce'], 'frameId': receipt['frameId'], 'seconds': time.monotonic() - started, 'evidence': str(log)}
        except subprocess.CalledProcessError as error:
            log.write_text((error.stdout or '') + (error.stderr or ''))
            failed = {'status': 'fail', 'seconds': time.monotonic() - started, 'evidence': str(log)}
            try:
                completion = windows.completion(error.stdout or '')
                failed.update(nonce=completion['nonce'], frameId=receipt['frameId'])
            except ValueError:
                pass
            return failed

    def binding(self):
        base = subprocess.check_output(['git', 'rev-parse', '--verify', '--end-of-options', self.args.source_commit + '^{commit}'], cwd=ROOT, text=True).strip()
        data = subprocess.check_output(['git', 'diff', base, '--', 'backend', 'docs', 'tools/release', 'tools/scripts', 'assets', '*.props', '*.targets', 'Directory.Build.*'], cwd=ROOT)
        dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--', 'backend', 'docs', 'tools/release', 'tools/scripts', 'assets', '*.props', '*.targets', 'Directory.Build.*'], cwd=ROOT, text=True)
        digest = hashlib.sha256(data).hexdigest()
        value = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'base': base, 'requestedSourceCommit': self.args.source_commit, 'productDiffBytes': len(data), 'productDiffSha256': digest, 'productStatus': dirty}
        self.save(self.out / 'p0/source-binding.json', value)
        if digest != EMPTY or dirty:
            raise RuntimeError('Product source differs from --source-commit; no build or PC mutation is allowed.')
        return value

    def source_version(self):
        project = ROOT / 'docs/internal/frontend/RooIndustries.OptimizationSuite.App/RooIndustries.OptimizationSuite.App.csproj'
        return ET.parse(project).find('.//Version').text.strip()

    def verified(self):
        if not self.args.published_installer:
            raise RuntimeError('--published-installer is required to verify the signed release identity.')
        directory = self.out / 'p0'
        directory.mkdir(exist_ok=True)
        manifest = directory / 'live-feed.json'
        with urlopen(Request(self.feed + '?t=' + str(int(time.time())), headers={'Cache-Control': 'no-cache'}), timeout=20) as response:
            if response.status != 200 or not response.url.startswith(self.feed + '?t='):
                raise RuntimeError('Live feed did not return HTTPS 200 at the committed URL.')
            data = response.read(65537)
            (directory / 'live-feed.headers.txt').write_text(str(response.headers))
        candidate = getattr(self.args, 'candidate', False)
        live = release_tool.verify_manifest(data, None if candidate else self.args.published_installer, self.feed)
        identity = release_tool.file_identity(self.args.published_installer)
        payload = live
        if candidate:
            version = release_tool.product_version(self.args.published_installer)
            if version != self.source_version():
                raise RuntimeError('Candidate ProductVersion differs from the bound source version.')
            payload = dict(live, version=version, installer={'url': None, 'size': identity[0], 'sha256': identity[1]})
        manifest.write_bytes(data)
        value = {'feedUrl': self.feed, 'keyId': json.loads(data)['keyId'], 'payload': payload, 'verifiedVersion': payload['version'], 'manifestSource': 'live HTTPS GET', 'liveRelease': live, 'candidateBootstrap': candidate, 'installerSource': 'local unpublished candidate' if candidate else 'signed live release', 'localInstaller': str(self.args.published_installer), 'localInstallerIdentity': release_tool.file_identity(self.args.published_installer), 'verification': 'ECDSA P-256 SHA-256 RFC3279 DER against tools/release/update-keys.json'}
        self.save(directory / 'verified-release.json', value)
        return value

    def frame(self, host, machine, label):
        path = self.out / (label + '-frame.json')
        if path.exists():
            receipt = json.loads(path.read_text())
            windows.validate_receipt(machine, receipt)
            windows.verify_local_source(host, machine, receipt)
            windows.enter_host_lease(host, machine, receipt)
            self.frames[host] = (machine, receipt)
            return receipt
        receipt = windows.upload_frame(host, machine, 'roo-industries-rc', True, r'C:\RooBuild')
        self.save(path, receipt)
        self.frames[host] = (machine, receipt)
        windows.enter_host_lease(host, machine, receipt)
        self.remote(host, machine, windows.harness_tree_helpers() + "$errors=@();Get-HarnessChildren " + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update') + " -Filter '*.ps1'|ForEach-Object {$tokens=$null;$parseErrors=$null;[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($_.LongPath),[ref]$tokens,[ref]$parseErrors)|Out-Null;$errors+=@($parseErrors)};@{errors=$errors.Count;detail=$errors}|ConvertTo-Json -Depth 10;if($errors.Count){throw 'PowerShell parse failed'}", self.out / 'p0' / (label + '-powershell-parse.json'))
        return receipt

    def preflight(self):
        script = windows.harness_tree_helpers() + r'''
$data=Join-Path $env:LOCALAPPDATA 'RooOptimizationSuite';$install='C:\Program Files\Roo Industries\Optimization Suite'
$key='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
$tasks=@(Get-ScheduledTask|ForEach-Object {@{name=$_.TaskName;path=$_.TaskPath;state=[string]$_.State;enabled=[bool]$_.Settings.Enabled;xml=(Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath)}})
$ts=Get-Command tailscale -ErrorAction SilentlyContinue;$binary=if($ts){$ts.Source}else{Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'}
$roots=@(foreach($name in 'RooOptimizationSuite','RooIndustriesOptimizationSuite'){$root=Join-Path $env:LOCALAPPDATA $name;@{path=$root;exists=(Test-HarnessPath $root);files=@(if(Test-HarnessPath $root){Get-HarnessTree $root -FilesOnly|ForEach-Object {@{path=$_.FullName.Substring($root.Length+1);bytes=$_.Length;sha256=(Get-HarnessFileSha256 $_.LongPath);attributes=[string]$_.Attributes}}})}})
$files=@(($roots|Where-Object path -eq $data).files)
@{machine=$env:COMPUTERNAME;timeUtc=[DateTime]::UtcNow.ToString('o');installedVersion=if(Test-HarnessPath $key){(Get-ItemProperty $key).DisplayVersion}else{$null};installExists=(Test-HarnessPath $install);dataRoot=$data;dataFiles=$files;dataRoots=$roots;tasks=$tasks;processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like ($install+'\*') -or $_.ExecutablePath -like 'C:\RooBuild\*' -or $_.CommandLine -like '*C:\RooBuild\*'}|Select-Object ProcessId,ParentProcessId,CreationDate,ExecutablePath,CommandLine);frames=@(if(Test-HarnessPath 'C:\RooBuild'){Get-HarnessChildren 'C:\RooBuild' -Directory|Select-Object Name,CreationTimeUtc,LastWriteTimeUtc});tailscale=if(Test-HarnessPath $binary){(& $binary serve status --json) -join "`n"|ConvertFrom-Json}else{$null};tailscaleBinary=if(Test-HarnessPath $binary){$binary}else{$null}}|ConvertTo-Json -Depth 30
'''
        rows = []
        for host, machine, label in [(self.args.host, self.args.expected_machine, '9070'), (self.args.blackwell_host, self.args.blackwell_machine, 'blackwell')]:
            if not host or not machine:
                rows.append({'check': label + ' preflight', 'status': 'unverified', 'observed': 'No host/machine arguments; no power action.'})
                continue
            path = self.out / 'p0' / (label + '-as-found.json')
            try:
                value = json.loads(self.remote(host, machine, script, path, timeout=windows.EVIDENCE_TIMEOUT))
            except windows.HostUnreachable:
                if label != 'blackwell':
                    raise
                rows.append({'check': 'blackwell reachable', 'status': 'unverified', 'observed': 'SSH unavailable; no power action.', 'evidence': str(path)})
                continue
            rows.append({'check': label + ' as-found state', 'status': 'pass', 'observed': {'installedVersion': value['installedVersion'], 'dataRoots': value['dataRoots'], 'dataFiles': len(value['dataFiles']), 'frames': len(value['frames']), 'activeFrameOrSuiteProcesses': value['processes'], 'cs2Tasks': [{k: t[k] for k in ('name', 'state', 'enabled')} for t in value['tasks'] if 'CS2' in t['name']], 'tailscaleBinary': value.get('tailscaleBinary')}, 'evidence': str(path)})
            if value['processes']:
                raise RuntimeError(label + ' has active Suite/frame processes; preserve them and stop preflight.')
        serve, _ = self.command(['tailscale', 'serve', 'status', '--json'])
        path = self.out / 'p0/linux-tailscale-as-found.json'
        if not path.exists():
            path.write_text(serve)
        if '8460' in serve:
            raise RuntimeError('Tailnet port 8460 is already occupied; never reuse or reset it.')
        rows.append({'check': 'tailnet 8460 absent', 'status': 'pass', 'observed': json.loads(serve), 'evidence': str(path)})
        release = self.verified()
        rows.append({'check': 'live signed feed matches published installer', 'status': 'pass', 'observed': release['localInstallerIdentity'], 'evidence': 'verified-release.json'})
        self.save(self.out / 'p0/receipt.json', {'part': 'p0', 'status': 'pass', 'source': self.binding(), 'checks': rows})

    def copy_to(self, host, local, remote):
        machine, receipt = self.frames[host]
        scope = '. ' + windows.ps_literal(receipt['stagingPath'] + '/tools/validation/Update/Harness.Common.ps1') + ';Open-HarnessRun ' + ' '.join(windows.ps_literal(receipt[k]) for k in ('runRoot', 'frameId', 'manifestSha256')) + ' ' + windows.ps_literal(receipt['frameId']) + ';'
        windows.invoke(host, machine, scope + 'if(Test-HarnessPath ' + windows.ps_literal(remote) + "){throw 'Upload input already exists; retained.'}")
        self.command(['scp', local, host + ':' + remote.replace('\\', '/')], host=host)
        windows.invoke(host, machine, scope + 'Register-HarnessFile ' + windows.ps_literal(remote) + " 'upload-input'|Out-Null")

    def copy_from(self, host, remote, local):
        local = Path(local)
        local.parent.mkdir(parents=True, exist_ok=True)
        self.command(['scp', host + ':' + remote.replace('\\', '/'), local], host=host)

    def inputs(self, host, machine, receipt):
        self.verified()
        pc = receipt['runRoot'] + r'\shipped'
        setup = '. ' + windows.ps_literal(receipt['stagingPath'] + '/tools/validation/Update/Harness.Common.ps1') + ';Open-HarnessRun ' + ' '.join(windows.ps_literal(receipt[k]) for k in ('runRoot', 'frameId', 'manifestSha256')) + ' ' + windows.ps_literal(receipt['frameId']) + ';Ensure-HarnessOutputDirectory ' + windows.ps_literal(pc)
        self.remote(host, machine, setup, self.out / 'p0' / (machine + '-directory.log'))
        import uuid
        inputs = pc + '\\inputs-' + uuid.uuid4().hex
        self.remote(host, machine, setup.rsplit(';Ensure-HarnessOutputDirectory', 1)[0] + ';New-HarnessDirectory ' + windows.ps_literal(inputs) + " 'harness-inputs'|Out-Null", self.out / 'p0' / (machine + '-inputs.log'))
        self.copy_to(host, self.out / 'p0/verified-release.json', inputs + r'\verified-release.json')
        return pc, inputs

    def extract(self):
        installer = self.args.published_installer
        if not installer:
            raise RuntimeError('--published-installer is required for installed payload verification.')
        verified = json.loads((self.out / 'p0/verified-release.json').read_text())
        release_tool.verify_manifest((self.out / 'p0/live-feed.json').read_bytes(), None if verified.get('candidateBootstrap') else installer, self.feed)
        if list(release_tool.file_identity(installer)) != verified['localInstallerIdentity']:
            raise RuntimeError('Local installer changed after verification; retained.')
        hashes = self.out / 'p0/payload-hashes.json'
        identity = release_tool.file_identity(installer)
        if hashes.exists():
            cached = json.loads(hashes.read_text())
            if cached.get('installerSha256') != identity[1] or cached.get('installerSize') != identity[0]:
                raise RuntimeError('Cached payload oracle belongs to another installer; preserve it and use a fresh output directory.')
            return hashes
        binary = self.args.innoextract or shutil.which('innoextract')
        if not binary:
            raise RuntimeError('innoextract is required; supply --innoextract without changing the shared system.')
        directory = self.out / 'p0/extracted'
        self.command([binary, '--version'], self.out / 'p0/innoextract-version.log')
        self.command([binary, '-d', directory, installer], self.out / 'p0/innoextract.log')
        app = directory / 'app'
        values = []
        for path in sorted(app.rglob('*')):
            if path.is_file():
                with path.open('rb') as source:
                    sha = hashlib.file_digest(source, 'sha256').hexdigest()
                values.append({'path': windows.safe_archive_path(path.relative_to(app).as_posix()).as_posix(), 'bytes': path.stat().st_size, 'sha256': sha})
        if not values or not any(v['path'] == 'app/RooIndustries.OptimizationSuite.App.exe' for v in values):
            raise RuntimeError('Extracted published installer has no expected app payload.')
        self.save(hashes, {'installerSha256': identity[1], 'installerSize': identity[0], 'files': values})
        self.save(self.out / 'p0/payload-source.json', {'installer': str(installer), 'identity': release_tool.file_identity(installer), 'verifiedVersion': verified['payload']['version'], 'method': 'innoextract', 'files': len(values)})
        return hashes

    def collect(self, host, machine, receipt, label):
        frame = receipt['runRoot']
        import uuid
        destination = frame + r'\shipped' + '\\evidence-' + uuid.uuid4().hex + '.zip'
        scope = '. ' + windows.ps_literal(receipt['stagingPath'] + '/tools/validation/Update/Harness.Common.ps1') + ';Open-HarnessRun ' + ' '.join(windows.ps_literal(receipt[k]) for k in ('runRoot', 'frameId', 'manifestSha256')) + ' ' + windows.ps_literal(receipt['frameId']) + ';'
        script = scope + r'''
$frame=FRAME;$destination=DEST
New-HarnessArchive $frame $destination {
 param($item,$relative)
 (Test-HarnessVisiblePath $item $frame) -and $relative -notmatch '^(source|source-alpha)\\|\\(source-B|source-alpha|work-[^\\]+|timer-source|timer-app|timer-core|client-probe|probe|stage|obj|bin)\\' -and [IO.Path]::GetExtension($item.FullName) -in '.json','.png','.log','.txt','.csv','.sha256'
}|Out-Null
'''.replace('FRAME', windows.ps_literal(frame)).replace('DEST', windows.ps_literal(destination))
        self.remote(host, machine, script, self.out / label / 'collect.log', timeout=windows.EVIDENCE_TIMEOUT)
        local = self.out / label / 'pc-evidence.zip'
        self.copy_from(host, destination, local)
        with zipfile.ZipFile(local) as bundle:
            for item in bundle.infolist():
                path = windows.safe_archive_path(item.filename)
                if path.is_absolute() or '..' in path.parts:
                    raise RuntimeError('Unsafe evidence archive member.')
                if not item.is_dir():
                    target = self.out / label / 'pc-artifacts' / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(bundle.read(item))

    def p1(self):
        host, machine = self.args.host, self.args.expected_machine
        if not self.args.test_feed_url or not self.args.signing_key:
            raise RuntimeError('p1 requires --test-feed-url and --signing-key (Linux only).')
        receipt = self.frame(host, machine, '9070')
        receipt_path = self.out / '9070-frame.json'
        full = self.out / 'p1/all'
        full.mkdir(parents=True, exist_ok=True)
        base = [sys.executable, '-I', ROOT / 'tools/validation/Update/run_e2e.py', '--host', host, '--expected-machine', machine, '--feed-url', self.args.test_feed_url, '--signing-key', self.args.signing_key, '--receipt', receipt_path, '--build-root', receipt['runRoot'] + r'\b', '--evidence-root', receipt['runRoot'] + r'\o']
        earlier = json.loads((self.out / 'p1/receipt.json').read_text()) if self.args.p1_extras_from or self.args.p1_from_scenario else None
        if earlier and (earlier.get('frameId') != receipt['frameId'] or any(row['status'] != 'pass' or row.get('frameId') != receipt['frameId'] for row in earlier['checks'])):
            raise RuntimeError('Resume requires earlier pass rows bound to the same frame receipt.')
        rows = earlier['checks'] if self.args.p1_extras_from else []
        if not self.args.p1_extras_from:
            self.save(self.out / 'p1/receipt.json', {'part': 'p1', 'frameId': receipt['frameId'], 'status': 'running', 'source': self.binding(), 'checks': rows})
            try:
                resume = ['--skip-build', '--skip-contracts', '--from-scenario', self.args.p1_from_scenario] if self.args.p1_from_scenario else []
                _, seconds = self.command(base + ['--scenario', 'all', '--out-dir', full, *resume], self.out / 'p1' / ('all-resume.log' if resume else 'all.log'))
            except Exception:
                rows.append({'check': 'all', 'status': 'fail', 'frameId': receipt['frameId'], 'evidence': 'all.log'})
                self.save(self.out / 'p1/receipt.json', {'part': 'p1', 'frameId': receipt['frameId'], 'status': 'fail', 'source': self.binding(), 'checks': rows})
                raise
            rows.append({'check': 'all', 'status': 'pass', 'frameId': receipt['frameId'], 'seconds': seconds, 'evidence': 'all/pc-artifacts'})
            self.save(self.out / 'p1/receipt.json', {'part': 'p1', 'frameId': receipt['frameId'], 'source': self.binding(), 'checks': rows})
        stage = receipt['runRoot'] + '\\b\\A\\work-' + self.source_version() + '\\stage'
        fixtures = receipt['runRoot'] + r'\o\timer-fixtures'
        if not self.args.p1_extras_from:
            result = self.desktop(host, machine, receipt, 'tools/validation/Background/Build-Review2Fixtures.ps1', {'Source': receipt['stagingPath'], 'Stage': stage, 'OutRoot': fixtures}, 'p1/timer-fixture', 10)
            if result['status'] != 'pass':
                raise RuntimeError('Timer fixture build failed; see its desktop log.')
        cases = [('contracts', 'contracts', []), ('transport-http', 'transport-error', ['--transport-fault', 'http-error']), ('transport-disconnect', 'transport-error', ['--transport-fault', 'disconnect']), ('settings-readonly', 'settings-readonly', []), ('timer-ready', 'ready', []), ('timer-read-failure', 'timer-read-failure', ['--fixture-exe', fixtures + r'\timer-app\app\RooIndustries.OptimizationSuite.App.exe']), ('manual-timeout', 'manual-timeout', [])]
        if self.args.p1_extras_from:
            cases = cases[[c[0] for c in cases].index(self.args.p1_extras_from):]
        for name, scenario, extra in cases:
            target = self.out / 'p1' / name
            target.mkdir(parents=True, exist_ok=True)
            link = target / 'builds'
            if not link.exists() and not link.is_symlink():
                link.symlink_to(full / 'builds', target_is_directory=True)
            if not link.is_symlink() or link.resolve() != (full / 'builds').resolve():
                raise RuntimeError('Existing builds symlink differs from this receipt.')
            try:
                _, seconds = self.command(base + ['--scenario', scenario, '--skip-build', '--out-dir', target, *extra], self.out / 'p1' / (name + '.log'))
            except Exception:
                rows.append({'check': name, 'status': 'fail', 'frameId': receipt['frameId'], 'evidence': name + '.log'})
                self.save(self.out / 'p1/receipt.json', {'part': 'p1', 'frameId': receipt['frameId'], 'status': 'fail', 'source': self.binding(), 'checks': rows})
                raise
            rows.append({'check': name, 'status': 'pass', 'frameId': receipt['frameId'], 'seconds': seconds, 'evidence': name + '/pc-artifacts'})
            self.save(self.out / 'p1/receipt.json', {'part': 'p1', 'frameId': receipt['frameId'], 'source': self.binding(), 'checks': rows})
        required = ['all', 'contracts', 'transport-http', 'transport-disconnect', 'settings-readonly', 'timer-ready', 'timer-read-failure', 'manual-timeout']
        complete = required_passes(rows, required, receipt['frameId'])
        all_rows = json.loads((full / 'scenario-results.json').read_text())
        complete = complete and all_rows['frameId'] == receipt['frameId'] and all_rows['manifestSha256'] == receipt['manifestSha256'] and required_passes(all_rows['checks'], ALL_SCENARIOS, receipt['frameId'])
        self.save(self.out / 'p1/receipt.json', {'part': 'p1', 'frameId': receipt['frameId'], 'status': 'pass' if complete else 'fail', 'required': required, 'source': self.binding(), 'checks': rows})
        if not complete:
            raise RuntimeError('Required P1 scenarios do not all have pass rows on this frame.')

    def shipped(self, part):
        if part == 'p5':
            host, machine, label = self.args.blackwell_host, self.args.blackwell_machine, 'blackwell'
            if not host or not machine:
                raise RuntimeError('p5 requires --blackwell-host and --blackwell-machine; never power on a PC.')
        else:
            host, machine, label = self.args.host, self.args.expected_machine, '9070'
        receipt = self.frame(host, machine, label)
        pc, inputs = self.inputs(host, machine, receipt)
        fields = {'Source': receipt['stagingPath'], 'OutRoot': pc, 'Part': part, 'ReleasePath': inputs + r'\verified-release.json', 'FrameId': receipt['frameId']}
        if part in ('p2', 'p2b', 'p3', 'p5'):
            hashes = self.extract()
            self.copy_to(host, hashes, inputs + r'\payload-hashes.json')
            fields['PayloadHashes'] = inputs + r'\payload-hashes.json'
        if getattr(self.args, 'candidate', False):
            candidate = inputs + '\\' + self.args.published_installer.name
            self.copy_to(host, self.args.published_installer, candidate)
            fields['CandidateInstaller'] = candidate
        if part in ('p2', 'p2b'):
            if not self.args.baseline_installer or not self.args.baseline_sha256:
                raise RuntimeError('p2 requires --baseline-installer and --baseline-sha256.')
            size, sha = release_tool.file_identity(self.args.baseline_installer)
            if sha != self.args.baseline_sha256.lower():
                raise RuntimeError('Baseline installer hash differs from --baseline-sha256; do not install it.')
            old = inputs + '\\' + self.args.baseline_installer.name
            self.copy_to(host, self.args.baseline_installer, old)
            fields['OldInstaller'] = old
            fields['OldVersion'] = release_tool.product_version(self.args.baseline_installer)
            self.save(self.out / part / 'old-installer.json', {'path': str(self.args.baseline_installer), 'size': size, 'sha256': sha, 'expectedSha256': self.args.baseline_sha256.lower(), 'productVersion': fields['OldVersion']})
        if part == 'p2b':
            probe = receipt['runRoot'] + r'\q'
            result = self.desktop(host, machine, receipt, 'tools/validation/Update/Build-ReleaseCandidate.ps1', {'Source': receipt['stagingPath'], 'OutRoot': probe, 'ProbeOnly': True}, 'p2b/build-probe', 10)
            if result['status'] != 'pass':
                self.collect(host, machine, receipt, part)
                raise RuntimeError('Candidate launch probe build failed.')
            fields['HandoffProbe'] = probe + r'\probe\UpdateProbe.exe'
        if part == 'p3':
            alpha = receipt['runRoot'] + r'\a'
            published_version = json.loads((self.out / 'p0/verified-release.json').read_text())['payload']['version']
            alpha_version = published_version.split('-', 1)[0].split('+', 1)[0] + '-alpha'
            published_app = inputs + r'\published-app.dll'
            self.copy_to(host, self.out / 'p0/extracted/app/app/RooIndustries.OptimizationSuite.App.dll', published_app)
            build = self.desktop(host, machine, receipt, 'tools/validation/Update/Build-ShippedAlpha.ps1', {'Source': receipt['stagingPath'], 'OutRoot': alpha, 'PublishedVersion': published_version, 'AlphaVersion': alpha_version, 'PublishedApp': published_app}, 'p3/build-alpha', 15)
            self.save(self.out / 'p3/build-receipt.json', build)
            if build['status'] != 'pass':
                self.collect(host, machine, receipt, part)
                raise RuntimeError('Production-feed alpha build failed.')
            alpha_fields = dict(fields, Part='p3-alpha', AlphaInstaller=alpha + '\\release\\RooIndustries-OptimizationSuite-' + alpha_version + '-setup.exe', AlphaVersion=alpha_version)
            result = self.desktop(host, machine, receipt, 'tools/validation/Update/Invoke-ShippedScenario.ps1', alpha_fields, 'p3/install-alpha', 15)
            if result['status'] != 'pass':
                self.collect(host, machine, receipt, part)
                raise RuntimeError('Alpha installation/preservation failed.')
        result = self.desktop(host, machine, receipt, 'tools/validation/Update/Invoke-ShippedScenario.ps1', fields, part, 25)
        self.save(self.out / part / 'run.json', result)
        self.collect(host, machine, receipt, part)
        if result.get('nonce'):
            self.save(self.out / part / 'receipt.json', windows.read_result(host, machine, receipt, 'receipt.json', result['nonce']))
        if result['status'] != 'pass':
            raise RuntimeError(f'{part} stopped; see receipt and failure.json. Product code stays unchanged.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scenario', required=True, choices=['p0', 'p1', 'p2', 'p2b', 'p3', 'p4', 'p5'])
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--host', default=os.environ.get('ROO_TEST_SSH_HOST'))
    parser.add_argument('--expected-machine', default=os.environ.get('ROO_TEST_COMPUTER'))
    parser.add_argument('--blackwell-host', default=os.environ.get('ROO_CCD_TEST_SSH_HOST'))
    parser.add_argument('--blackwell-machine', default=os.environ.get('ROO_CCD_TEST_COMPUTER'))
    parser.add_argument('--test-feed-url', default=os.environ.get('ROO_TEST_UPDATE_FEED'))
    parser.add_argument('--signing-key', type=Path, default=os.environ.get('ROO_UPDATE_SIGNING_KEY'))
    parser.add_argument('--published-installer', type=Path)
    parser.add_argument('--candidate', action='store_true', help='P2/P2b only: stage an unpublished local installer; verify the signed live feed independently and never GET the candidate URL.')
    parser.add_argument('--baseline-installer', type=Path)
    parser.add_argument('--baseline-sha256')
    parser.add_argument('--innoextract', type=Path)
    parser.add_argument('--p1-from-scenario', help='Resume the all journey on its existing receipt after an environmental or harness interruption; completed builds and contracts stay frozen.')
    parser.add_argument('--p1-extras-from', choices=['contracts', 'transport-http', 'transport-disconnect', 'settings-readonly', 'timer-ready', 'timer-read-failure', 'manual-timeout'])
    parser.add_argument('--out-dir', type=Path, default=ROOT / 'artifacts/roo-29')
    args = parser.parse_args()
    if not args.host or not args.expected_machine:
        parser.error('--host and --expected-machine (or ROO_TEST_SSH_HOST / ROO_TEST_COMPUTER) are required.')
    if args.scenario != 'p1' and not args.published_installer:
        parser.error('--published-installer is required for p0 and p2-p5.')
    if args.candidate and args.scenario not in ('p2', 'p2b'):
        parser.error('--candidate is only available for p2/p2b.')
    if args.scenario == 'p2b' and not args.candidate:
        parser.error('p2b is a local candidate installer-launch stand-in; --candidate is required.')
    if args.scenario in ('p2', 'p2b') and (not args.baseline_installer or not args.baseline_sha256 or not re.fullmatch(r'[0-9a-fA-F]{64}', args.baseline_sha256)):
        parser.error('p2 requires --baseline-installer and a 64-hex --baseline-sha256.')
    if args.signing_key:
        windows.assert_external_signing_key(args.signing_key)
    journey = Journey(args)
    journey.binding()
    if args.scenario == 'p0':
        journey.preflight()
    elif args.scenario == 'p1':
        windows.assert_external_signing_key(args.signing_key)
        journey.p1()
    else:
        journey.shipped(args.scenario)


if __name__ == '__main__':
    main()
