import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import concurrent.futures

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--expected-machine', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--published-installer', type=Path, required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    windows = load('harness_windows', ROOT / 'tools/validation/windows_ssh.py')
    shipped = load('harness_shipped', ROOT / 'tools/validation/Update/run_shipped.py')
    args.signing_key = None
    journey = shipped.Journey(args)
    rows = []

    def refused(name, action, expected):
        try:
            action()
        except (RuntimeError, ValueError) as error:
            if expected not in str(error):
                raise
            rows.append({'check': name, 'status': 'pass', 'observed': str(error)})
        else:
            raise RuntimeError(name + ' did not refuse')

    dummy = ROOT / 'tools/validation/Update/roo-key-fixture.pem'
    with dummy.open('x') as output:
        output.write('DUMMY FIXTURE - NO KEY')
    try:
        refused('in-repository signing key rejected', lambda: windows.assert_external_signing_key(dummy), 'outside')
        refused('upload rejects PEM before SSH', lambda: windows.upload('must-not-contact', 'must-not-contact', 'roo-industries-harness', True, r'C:\RooBuild'), 'cannot be staged')
    finally:
        dummy.unlink()
    extensionless = ROOT / 'tools/release/update-signing-private'
    if extensionless.exists():
        raise RuntimeError('Private-marker fixture path already exists; retained.')
    extensionless.write_bytes(b'-----BEGIN EC ' + b'PRIVATE ' + b'KEY-----\nDUMMY\n-----END EC ' + b'PRIVATE ' + b'KEY-----\n')
    try:
        refused('F7 extensionless PEM content rejected before SSH', lambda: windows.upload('must-not-contact', 'must-not-contact', 'roo-industries-harness', True, r'C:\RooBuild'), 'cannot be staged')
    finally:
        extensionless.unlink()
    extensionless.write_bytes(bytes.fromhex('3014020103300f06092a864886f70d010701a0020400'))
    try:
        refused('F7 extensionless PKCS12 DER rejected before SSH', lambda: windows.upload('must-not-contact', 'must-not-contact', 'roo-industries-harness', True, r'C:\RooBuild'), 'cannot be staged')
    finally:
        extensionless.unlink()
    result = subprocess.run([__import__('sys').executable, '-I', str(ROOT / 'tools/validation/Update/run_e2e.py'), '--scenario', 'contracts', '--skip-contracts'], capture_output=True, text=True)
    if result.returncode != 2 or 'cannot be combined' not in result.stderr:
        raise RuntimeError('F14 skipped contracts did not fail in argparse before networking')
    rows.append({'check': 'F14 contracts cannot be skipped', 'status': 'pass', 'observed': result.stderr.strip()})
    props = ROOT / 'RooHarnessFixture.props'
    with props.open('x') as output:
        output.write('<Project/>')
    try:
        refused('untracked root build property rejected', journey.binding, 'Product source differs')
    finally:
        props.unlink()
    required = shipped.ALL_SCENARIOS
    complete = [{'check': name, 'status': 'pass'} for name in required]
    complete[3]['status'] = 'fail'
    if shipped.required_passes(complete, required):
        raise RuntimeError('Failed P1 receipt was accepted')
    rows.append({'check': 'P1 failed scenario cannot pass final receipt', 'status': 'pass', 'observed': complete[3]})
    wrong_frame = [{'check': name, 'status': 'pass', 'frameId': 'other-frame'} for name in required]
    if shipped.required_passes(wrong_frame, required, 'this-frame'):
        raise RuntimeError('P1 rows from another frame were accepted')
    rows.append({'check': 'P1 refuses pass rows from another frame', 'status': 'pass', 'observed': 'other-frame rows => fail'})
    journey.binding()
    frozen = ROOT.parents[2] / 'artifacts/roo-29/p2-real-0.10/p0'
    if not frozen.is_dir():
        frozen = ROOT.parents[2] / 'artifacts/roo-29/p0'
    import shutil
    for name in ('live-feed.json', 'verified-release.json'):
        shutil.copyfile(frozen / name, args.out_dir / 'p0' / name)
    stale = {'installerSha256': '0' * 64, 'installerSize': 1, 'files': []}
    (args.out_dir / 'p0/payload-hashes.json').write_text(json.dumps(stale))
    refused('stale payload oracle rejected', journey.extract, 'another installer')
    (args.out_dir / 'p0/payload-hashes.json').unlink()
    receipt = windows.upload(args.host, args.expected_machine, 'roo-industries-roo29-shipped', True, r'C:\RooBuild')
    (args.out_dir / 'frame.json').write_text(json.dumps(receipt, indent=2))
    windows.verify_local_source(args.host, args.expected_machine, receipt)
    path = ROOT / 'tools/validation/Update/README.md'
    original = path.read_bytes()
    try:
        path.write_bytes(original + b'\nFixture change after staging\n')
        refused('changed local harness rejects frame reuse', lambda: windows.verify_local_source(args.host, args.expected_machine, receipt), 'stage a fresh frame')
    finally:
        path.write_bytes(original)
    parse = "$errors=@();Get-ChildItem -LiteralPath " + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update') + " -Filter '*.ps1'|ForEach-Object {$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e)|Out-Null;$errors+=@($e)};@{errors=$errors.Count;detail=$errors}|ConvertTo-Json -Depth 10;if($errors.Count){throw 'Parse failed'}"
    result = windows.invoke(args.host, args.expected_machine, parse)
    (args.out_dir / 'powershell-parse.json').write_text(result.stdout)
    try:
        result = windows.interactive(args.host, args.expected_machine, receipt, 'tools/validation/Update/Invoke-HarnessChecks.ps1', {'Source': receipt['stagingPath'], 'OutRoot': receipt['runRoot'] + r'\checks'}, 8)
    except subprocess.CalledProcessError as error:
        (args.out_dir / 'desktop.log').write_text((error.stdout or '') + (error.stderr or ''))
        raise RuntimeError('Owned harness fixture failed; see desktop.log') from None
    (args.out_dir / 'desktop.log').write_text(result.stdout)
    completion = windows.completion(result.stdout)
    pc_receipt = windows.read_result(args.host, args.expected_machine, receipt, 'receipt.json', completion['nonce'])
    (args.out_dir / 'windows-receipt.json').write_text(json.dumps(pc_receipt, indent=2))
    rows.extend(pc_receipt['checks'])
    guard_scope = '. ' + windows.ps_literal(receipt['stagingPath'] + '/tools/validation/Update/Harness.Common.ps1') + ';Open-HarnessRun ' + ' '.join(windows.ps_literal(receipt[k]) for k in ('runRoot', 'frameId', 'manifestSha256')) + ' ' + windows.ps_literal(receipt['frameId'])
    extra = receipt['stagingPath'] + r'\Directory.Build.targets'
    windows.invoke(args.host, args.expected_machine, guard_scope + ';$entry=New-HarnessText ' + windows.ps_literal(extra) + " '<Project/>' 'extra-targets';$entry.id")
    refused('F8 extra remote Directory.Build.targets refuses reuse', lambda: windows.verify_source(args.host, args.expected_machine, receipt), 'Staged source file set differs')
    windows.invoke(args.host, args.expected_machine, guard_scope + ';$entry=@(Get-HarnessEntries|Where-Object {$_.identity.path -ieq ' + windows.ps_literal(extra) + " -and $_.state -eq 'active'})[0];Remove-HarnessEntry $entry")
    other = windows.upload(args.host, args.expected_machine, 'roo-industries-roo29-shipped', True, r'C:\RooBuild')
    (args.out_dir / 'other-frame.json').write_text(json.dumps(other, indent=2))
    other_scope = ". " + windows.ps_literal(other["stagingPath"] + "/tools/validation/Update/Harness.Common.ps1") + ";Open-HarnessRun " + " ".join(windows.ps_literal(other[k]) for k in ("runRoot", "frameId", "manifestSha256")) + " " + windows.ps_literal(other["frameId"]) + ";"
    foreign_directory = receipt['runRoot'] + r'\foreign-empty-directory'
    windows.invoke(args.host, args.expected_machine, other_scope + "New-HarnessDirectory " + windows.ps_literal(foreign_directory) + " 'foreign-empty-directory'|Out-Null")
    clear = '& ' + windows.ps_literal(receipt['stagingPath'] + '/tools/validation/Update/Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(receipt['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine)
    try:
        windows.invoke(args.host, args.expected_machine, clear, timeout=windows.CLEANUP_TIMEOUT)
    except subprocess.CalledProcessError as error:
        observed = (error.stdout or '') + (error.stderr or '')
        if 'Unrecorded frame directory retained; ledger kept' not in observed:
            raise
        retained = windows.invoke(args.host, args.expected_machine, "(Test-Path " + windows.ps_literal(receipt['runRoot'] + r'\ledger.json') + ") -and (Test-Path " + windows.ps_literal(receipt['stagingPath'] + r'\source-verification.json') + ")").stdout.strip()
        if retained != 'True':
            raise RuntimeError('Empty-directory refusal lost the frame ledger or source')
        rows.append({'check': 'unrecorded empty frame directory refuses cleanup and keeps ledger/source', 'status': 'pass', 'observed': observed.strip()})
    else:
        raise RuntimeError('Frame cleanup removed another run\'s empty directory')
    windows.invoke(args.host, args.expected_machine, other_scope + "$entry=@(Get-HarnessEntries|Where-Object {$_.identity.path -ieq " + windows.ps_literal(foreign_directory) + "})[0];Remove-HarnessEntry $entry")
    result = windows.invoke(args.host, args.expected_machine, '& ' + windows.ps_literal(other['stagingPath'] + '/tools/validation/Update/Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(other['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine), timeout=windows.CLEANUP_TIMEOUT)
    (args.out_dir / 'other-cleanup.json').write_text(result.stdout)
    held_frame = windows.upload(args.host, args.expected_machine, 'roo-industries-roo29-shipped', True, r'C:\RooBuild')
    (args.out_dir / 'held-frame.json').write_text(json.dumps(held_frame, indent=2))
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        running = pool.submit(windows.interactive, args.host, args.expected_machine, held_frame, 'tools/validation/Update/Invoke-HarnessChecks.ps1', {'Source': held_frame['stagingPath'], 'OutRoot': held_frame['runRoot'] + r'\checks', 'Hold': True}, 2)
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            held_scope = ". " + windows.ps_literal(held_frame["stagingPath"] + "/tools/validation/Update/Harness.Common.ps1") + ";Open-HarnessRun " + " ".join(windows.ps_literal(held_frame[k]) for k in ("runRoot", "frameId", "manifestSha256")) + " " + windows.ps_literal(held_frame["frameId"]) + " -ReadOnly;"
            live = windows.invoke(args.host, args.expected_machine, held_scope + "@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.purpose -eq 'interactive-child' -and $_.state -eq 'active'}).Count").stdout.strip()
            if live == '1':
                break
            if running.done():
                running.result()
                raise RuntimeError('Real interactive runner ended before the guard check')
            time.sleep(0.2)
        else:
            raise RuntimeError('Real interactive child did not enter its ledger')
        call = '& ' + windows.ps_literal(held_frame['stagingPath'] + '/tools/validation/Update/Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(held_frame['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine)
        try:
            windows.invoke(args.host, args.expected_machine, call, timeout=windows.CLEANUP_TIMEOUT)
        except subprocess.CalledProcessError as error:
            observed = (error.stdout or '') + (error.stderr or '')
            if not any(text in observed for text in ('Encoded PowerShell', 'running processes', 'runner child')):
                raise
            rows.append({'check': 'F6 REAL windows_ssh interactive encoded runner prevents frame cleanup', 'status': 'pass', 'observed': observed.strip()})
        else:
            raise RuntimeError('Frame cleanup removed a live real interactive frame')
        finished = running.result()
        (args.out_dir / 'real-interactive.log').write_text(finished.stdout)
    cleared = windows.invoke(args.host, args.expected_machine, call, timeout=windows.CLEANUP_TIMEOUT)
    (args.out_dir / 'held-cleanup.json').write_text(cleared.stdout)
    cleanup = '& ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(receipt['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine)
    result = windows.invoke(args.host, args.expected_machine, cleanup, timeout=windows.CLEANUP_TIMEOUT)
    (args.out_dir / 'cleanup.json').write_text(result.stdout)
    (args.out_dir / 'receipt.json').write_text(json.dumps({'status': 'pass', 'checks': rows}, indent=2))
    print('PASS ' + str(len(rows)) + ' targeted harness checks')


if __name__ == '__main__':
    main()
