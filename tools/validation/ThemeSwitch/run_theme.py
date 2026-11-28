import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_ssh', ROOT / 'tools/validation/windows_ssh.py')
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)
spec = importlib.util.spec_from_file_location('local_tree', ROOT / 'tools/validation/local_tree.py')
tree = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tree)
local_tree = tree.entries


def scope(frame):
    return (windows.harness_tree_helpers() + '\n. (Get-HarnessToolPath ' + windows.ps_literal(frame['stagingPath'] + '/tools/validation/Update/Harness.Common.ps1') +
            ');Open-HarnessRun ' + ' '.join(windows.ps_literal(frame[k]) for k in ['runRoot', 'frameId', 'manifestSha256']) + ' ' + windows.ps_literal(frame['frameId']) + ';')


def lease(args, frame):
    deadline = time.monotonic() + args.lease_minutes * 60
    while True:
        try:
            return windows.enter_host_lease(args.host, args.expected_machine, frame)
        except subprocess.CalledProcessError as error:
            if 'leased by frame' not in (error.stdout or '') + (error.stderr or '') or time.monotonic() > deadline:
                raise
            print('Test PC is leased by another run; waiting.', flush=True)
            time.sleep(60)


def collect(args, frame, evidence, out):
    path = frame['runRoot'] + '\\theme-evidence.zip'
    remote = windows.invoke(args.host, args.expected_machine, scope(frame) + 'New-HarnessArchive ' + windows.ps_literal(evidence) + ' ' + windows.ps_literal(path) +
                            ' {param($item,$relative) $true}|Out-Null;Register-HarnessFile ' + windows.ps_literal(path) + " 'theme-evidence'|Out-Null;Get-HarnessFileSha256 " + windows.ps_literal(path),
                            timeout=windows.EVIDENCE_TIMEOUT).stdout.strip()
    local = out / 'evidence.zip'
    windows.run_transport(args.host, 'scp', [args.host + ':' + path.replace('\\', '/'), str(local)], timeout=windows.TRANSFER_TIMEOUT, capture_output=True, text=True)
    if subprocess.check_output(['sha256sum', str(local)], text=True).split()[0].upper() != remote.upper():
        raise ValueError('Downloaded evidence hash differs')
    with zipfile.ZipFile(local) as archive:
        for name in archive.namelist():
            windows.safe_archive_path(name)
        if any(tree.linked(p.lstat()) for p in local_tree(out / 'evidence', links=True)):
            raise RuntimeError('The evidence folder is or holds a link, so the archive is not extracted into it.')
        archive.extractall(out / 'evidence')


def clear(args, frame, out):
    result = windows.invoke(args.host, args.expected_machine, '& ' + windows.ps_literal(frame['stagingPath'] + '/tools/validation/Update/Clear-UpdateFrame.ps1') +
                            ' -Frame ' + windows.ps_literal(frame['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine), timeout=windows.CLEANUP_TIMEOUT)
    (out / 'closed-ledger.json').write_text(result.stdout)
    ledger = json.loads(result.stdout)
    if any(e['state'] in ('active', 'error') for e in ledger['entries']) or any(i['status'] == 'running' for i in ledger['invocations']):
        raise RuntimeError('Creation ledger did not close')


def encode(out, summary):
    video = summary.get('video')
    if not video or not video.get('frames'):
        return None
    folder = out / 'evidence' / video['folder']
    boxes = [f"drawbox=x={r[0]}:y={r[1]}:w={r[2]}:h={r[3]}:color=black:t=fill:enable='between(n,{span['from']},{span['to']})'"
             for span in summary.get('privateFrames') or [] for r in span['rects'] or []]
    target = out / 'theme-switch.mp4'
    subprocess.run(['/usr/bin/ffmpeg', '-nostdin', '-v', 'error', '-y', '-framerate', str(video['fps']), '-i', str(folder / 'frame-%07d.jpg'),
                    '-vf', ','.join(boxes + ['scale=ceil(iw/2)*2:ceil(ih/2)*2']), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                    '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(target)], check=True)
    return target


def main():
    parser = argparse.ArgumentParser(description='Theme switch keeps work in progress: real app on a Windows test PC.')
    parser.add_argument('--host', required=True)
    parser.add_argument('--expected-machine', required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    parser.add_argument('--lease-minutes', type=float, default=60)
    parser.add_argument('--fail-before-undo', action='store_true')
    args = parser.parse_args()
    out = args.out_dir
    out.mkdir(parents=True)
    frame = windows.upload_frame(args.host, args.expected_machine, 'roo-industries-theme', True, r'C:\RooBuild')
    (out / 'frame.json').write_text(json.dumps(frame, indent=2))
    result = {'status': 'fail'}
    errors = []
    try:
        lease(args, frame)
        windows.verify_local_source(args.host, args.expected_machine, frame)
        run = windows.interactive_frame(args.host, args.expected_machine, frame, 'tools/validation/ThemeSwitch/Invoke-ThemeSwitch.ps1',
                                        {'Source': frame['stagingPath'], 'OutRoot': frame['runRoot'] + '\\theme', **({'FailBeforeUndo': True} if args.fail_before_undo else {})}, 40)
        (out / 'run.log').write_text(run.stdout)
        completion = windows.completion(run.stdout)
        receipt = windows.read_result(args.host, args.expected_machine, frame, 'receipt.json', completion['nonce'])
        result.update(receipt=receipt, harnessPassed=completion['passed'])
        collect(args, frame, receipt['evidence'], out)
    except BaseException as error:
        result['failure'] = repr(error)
        if isinstance(error, subprocess.CalledProcessError):
            (out / 'failure.log').write_text((error.stdout or '') + (error.stderr or ''))
    finally:
        try:
            clear(args, frame, out)
        except BaseException as error:
            errors.append('Frame cleanup: ' + repr(error))
            result['retainedFrame'] = frame['runRoot']
    summaries = sorted((out / 'evidence').glob('summary-*.json')) if (out / 'evidence').exists() else []
    if summaries:
        summary = json.loads(summaries[-1].read_text(encoding='utf-8-sig'))['data']
        result['checks'] = summary['checks']
        try:
            result['video'] = str(encode(out, summary))
        except subprocess.CalledProcessError as error:
            errors.append('Video: ' + repr(error))
    result['cleanupErrors'] = errors
    result['status'] = 'pass' if result.get('receipt', {}).get('status') == 'pass' and result.get('harnessPassed') and not errors and 'failure' not in result else 'fail'
    (out / 'result.json').write_text(json.dumps(result, indent=2))
    for check in result.get('checks', []):
        print(('PASS ' if check['passed'] else 'FAIL ') + check['check'])
    print('Theme switch check: ' + result['status'])
    return 0 if result['status'] == 'pass' else 1


if __name__ == '__main__':
    raise SystemExit(main())
