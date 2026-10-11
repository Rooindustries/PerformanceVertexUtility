import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

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
    dummy.write_text('DUMMY FIXTURE - NO KEY')
    try:
        refused('in-repository signing key rejected', lambda: windows.assert_external_signing_key(dummy), 'outside')
        refused('upload rejects PEM before SSH', lambda: windows.upload('must-not-contact', 'must-not-contact', 'roo-industries-harness', True, r'C:\RooBuild'), 'cannot be staged')
    finally:
        dummy.unlink()
    props = ROOT / 'RooHarnessFixture.props'
    props.write_text('<Project/>')
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
    subprocess.run(['scp', *windows.SSH_OPTIONS, args.host + ':' + (receipt['runRoot'] + '/checks/receipt.json').replace('\\', '/'), str(args.out_dir / 'windows-receipt.json')], check=True, capture_output=True)
    rows.extend(json.loads((args.out_dir / 'windows-receipt.json').read_text()))
    cleanup = '& ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(receipt['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine)
    result = windows.invoke(args.host, args.expected_machine, cleanup)
    (args.out_dir / 'cleanup.json').write_text(result.stdout)
    (args.out_dir / 'receipt.json').write_text(json.dumps({'status': 'pass', 'checks': rows}, indent=2))
    print('PASS ' + str(len(rows)) + ' targeted harness checks')


if __name__ == '__main__':
    main()
