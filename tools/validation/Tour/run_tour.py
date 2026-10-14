import argparse
import json
from pathlib import Path
import shutil
import subprocess
import zipfile

import importlib.util

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


memory = load('tour_memory', ROOT / 'tools/validation/Memory/run_memory.py')


class Tour(memory.Measurement):
    def download(self, remote, local, expected=None):
        self.windows.run_transport(self.args.host, 'scp', [self.args.host + ':' + remote.replace('\\', '/'), str(local)],
                                   timeout=1800, capture_output=True, text=True)
        if expected and memory.identity(local)['sha256'].upper() != expected.upper():
            raise ValueError('Downloaded evidence hash differs: ' + str(local))

    def collect(self):
        w, f = self.windows, self.frame
        path = f['runRoot'] + '\\evidence.zip'
        remote = self.invoke(self.scope() + 'New-HarnessArchive ' + w.ps_literal(f['runRoot']) + ' ' + w.ps_literal(path) +
                             " {param($item,$relative) $relative=$relative.Replace('\\','/');$relative -notmatch '^(Source|source|inputs|b/release|b/heap|b/probe)/' -and $relative -ne 'evidence.zip'}|Out-Null;Get-HarnessFileSha256 " + w.ps_literal(path), timeout=1800)
        local = self.out / 'evidence.zip'
        self.download(path, local, remote.stdout.strip())
        with zipfile.ZipFile(local) as archive:
            for name in archive.namelist():
                w.safe_archive_path(name)
            archive.extractall(self.out / 'evidence')

    def desktop(self, name, fields, minutes, suite='Tour'):
        w = self.windows
        result = w.interactive_frame(self.args.host, self.args.expected_machine, self.frame,
                                     'tools/validation/' + suite + '/' + name + '.ps1', fields, minutes)
        (self.out / (name + '.log')).write_text(result.stdout)
        completion = w.completion(result.stdout)
        memory.save(self.out / (name + '-completion.json'), completion)
        if not completion['passed']:
            raise RuntimeError(name + ' did not complete')
        receipt = w.read_result(self.args.host, self.args.expected_machine, self.frame, 'receipt.json', completion['nonce'])
        if receipt['status'] != 'pass':
            raise RuntimeError('Desktop scenario failed')
        return completion, receipt

    def restore(self):
        original = self.desktop
        self.desktop = lambda name, fields, minutes: original(name, fields, minutes, 'Memory')
        try:
            super().restore()
        finally:
            self.desktop = original

    def run(self):
        checks, errors = [], []
        restored = True
        result = {'status': 'fail', 'checks': checks, 'cleanupErrors': errors, 'completedInstallerDownloads': 0}
        try:
            w = self.windows
            self.frame = w.upload_frame(self.args.host, self.args.expected_machine, 'roo-industries-tour', True, r'C:\RooBuild')
            memory.save(self.out / 'frame.json', self.frame)
            w.enter_host_lease(self.args.host, self.args.expected_machine, self.frame)
            w.verify_local_source(self.args.host, self.args.expected_machine, self.frame)
            self.restore_remote = self.input(self.args.restore_installer, 'restore.exe')
            self.preflight()
            candidate = self.input(self.args.installer, 'candidate.exe')
            parse = self.invoke(self.scope() + '$rows=@();foreach($file in Get-HarnessTree ' + w.ps_literal(self.frame['stagingPath'] + '/tools/validation/Tour') + " -FilesOnly|Where-Object {[IO.Path]::GetExtension($_.FullName) -ieq '.ps1'}){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($file.LongPath),[ref]$tokens,[ref]$errors)|Out-Null;$rows+=@{path=$file.FullName;errors=@($errors|ForEach-Object {$_.Message})}};@{powershell=$PSVersionTable.PSVersion.ToString();files=$rows}|ConvertTo-Json -Depth 10")
            (self.out / 'parse.json').write_text(parse.stdout)
            parsed = json.loads(parse.stdout)
            if any(r['errors'] for r in parsed['files']):
                raise ValueError('PowerShell parse failed')
            checks.append({'check': 'PS 5.1 parse', 'observed': parsed['powershell'], 'passed': parsed['powershell'].startswith('5.1.')})
            _, inspection = self.desktop('Inspect-Tour', {'Source': self.frame['stagingPath'], 'OutRoot': self.frame['runRoot'] + '\\inspect'}, 3)
            memory.save(self.out / 'desktop-inspection.json', inspection)
            if inspection['width'] < 1600 or inspection['height'] < 1000:
                raise RuntimeError('Signed-in desktop cannot contain 1600x1000: ' + inspection['workArea'])
            self.modified_install = True
            self.desktop('Install-MemoryBuild', {'Source': self.frame['stagingPath'], 'OutRoot': self.frame['runRoot'] + '\\candidate-install', 'Installer': candidate, 'ExpectedVersion': self.args.version, 'Sha256': self.args.sha256.upper()}, 10, 'Memory')
            completion, capture = self.desktop('Invoke-AppTour', {
                'Source': self.frame['stagingPath'], 'OutRoot': self.frame['runRoot'] + '\\tour',
                'ExpectedVersion': self.args.version,
                'HoldSeconds': self.args.hold_seconds, 'Passes': self.args.passes}, 90)
            memory.save(self.out / 'capture.json', capture)
            checks.extend([
                {'check': 'candidate upgrade before app tour', 'passed': capture['version'] == self.args.version},
                {'check': 'original appearance restored in Settings', 'passed': capture['appearanceRestored']},
                {'check': 'all app screenshots are 1600x1000 DWM bounds', 'passed': all(s['width'] == 1600 and s['height'] == 1000 for s in capture['screens'] if s['pass'] != 'installer')},
                {'check': 'all app actions use allowed UIA patterns without clicks', 'passed': all(not a['mouseClick'] and a['result'] == 'success' for a in capture['actions'])},
            ])
        except BaseException as error:
            result['failure'] = memory.describe_error(error)
            if isinstance(error, subprocess.CalledProcessError):
                (self.out / 'failure.log').write_text((error.stdout or '') + (error.stderr or ''))
        finally:
            if self.frame:
                if self.modified_install and self.before:
                    try:
                        self.restore()
                    except BaseException as error:
                        restored = False
                        errors.append('Restore: ' + memory.describe_error(error))
                try:
                    self.collect()
                except BaseException as error:
                    errors.append('Evidence: ' + memory.describe_error(error))
                if restored and not any(e.startswith('Evidence:') for e in errors):
                    try:
                        self.clear()
                    except BaseException as error:
                        errors.append('Frame cleanup: ' + memory.describe_error(error))
                else:
                    result['retainedFrame'] = self.frame['runRoot']
                if self.before:
                    try:
                        after = self.final_snapshot()
                        audit = memory.cleanup_checks(self.before, after, self.frame)
                        memory.save(self.out / 'cleanup-audit.json', {'status': 'pass' if all(audit.values()) else 'fail', 'checks': audit})
                        checks.extend({'check': name, 'passed': passed} for name, passed in audit.items())
                    except BaseException as error:
                        errors.append('Audit: ' + memory.describe_error(error))
            result['status'] = 'pass' if checks and all(c['passed'] for c in checks) and not errors and 'failure' not in result else 'fail'
            memory.save(self.out / 'receipt.json', result)
        return result


def encode(out, capture, hold, accepted):
    from PIL import Image, ImageDraw
    extracted = out / 'evidence'
    action_files = list(extracted.rglob(Path(capture['actionLog']['path'].replace('\\', '/')).name))
    if len(action_files) != 1 or memory.identity(action_files[0])['sha256'].upper() != capture['actionLog']['sha256']:
        raise ValueError('Action log identity differs')
    screens, installer = out / 'screens', out / 'installer'
    screens.mkdir(exist_ok=True)
    installer.mkdir(exist_ok=True)
    listing = []
    for shot in capture['screens']:
        origin = Path(shot.get('evidenceRoot', extracted))
        matches = list(origin.rglob(shot['file']))
        if len(matches) != 1 or memory.identity(matches[0])['sha256'].upper() != shot['sha256']:
            raise ValueError('Screenshot identity differs: ' + shot['file'])
        target = (installer if shot['pass'] == 'installer' else screens) / shot['file']
        shutil.copyfile(matches[0], target)
        listing.append((target.relative_to(out).as_posix(), shot['pass'] + ': ' + shot['page'] + ', ' + shot['tab'] + (', scroll part ' + str(shot['part']) if shot['part'] else '')))
    for name in ['tour']:
        info = capture['movies'][name]
        segments = info.get('segments', [dict(info, evidenceRoot=str(extracted))])
        folder = out / 'encoding-frames'
        folder.mkdir(exist_ok=False)
        number = 0
        for segment in segments:
            relative = segment['folder'].split('\\tour\\', 1)[1]
            source = Path(segment['evidenceRoot']) / 'tour' / relative.replace('\\', '/')
            frames = sorted(source.glob('frame-*.jpg'))
            if len(frames) != segment['frames'] or not frames:
                raise ValueError('Video frame count differs')
            for frame in frames:
                number += 1
                (folder / ('frame-%07d.jpg' % number)).hardlink_to(frame)
        output = out / (name + '.mp4')
        subprocess.run(['/usr/bin/ffmpeg', '-nostdin', '-v', 'error', '-y', '-framerate', '15', '-i', str(folder / 'frame-%07d.jpg'),
                        '-vf', 'scale=ceil(iw/2)*2:ceil(ih/2)*2', '-c:v', 'libx264', '-preset', 'medium', '-crf', '20',
                        '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(output)], check=True)
        metadata = json.loads(subprocess.check_output(['/usr/bin/ffprobe', '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(output)], text=True))
        memory.save(out / (name + '-video.json'), metadata)
        listing.append((output.name, name + ' tour, real cursor, H.264, 15 fps'))
    for letter in ['A', 'B', 'C']:
        shots = [s for s in capture['screens'] if s['pass'] == letter]
        columns = 4
        sheet = Image.new('RGB', (columns * 400, ((len(shots) + columns - 1) // columns) * 285), '#151515')
        draw = ImageDraw.Draw(sheet)
        for i, shot in enumerate(shots):
            with Image.open(screens / shot['file']) as image:
                image.thumbnail((390, 245))
                x, y = i % columns * 400, i // columns * 285
                sheet.paste(image, (x + 5, y + 5))
                draw.text((x + 5, y + 251), shot['file'][:57], fill='white')
        target = out / ('contact-sheet-' + letter + '.png')
        sheet.save(target)
        listing.append((target.name, 'Pass ' + letter + ' contact sheet'))
    accepted_receipt = json.loads((accepted / 'source-binding.json').read_text())
    for path in sorted((accepted / 'installer').glob('*.png')):
        shutil.copyfile(path, installer / path.name)
        listing.append(('installer/' + path.name, 'Accepted interactive wizard screenshot'))
    for name in ['installer.mp4', 'installer-video.json']:
        shutil.copyfile(accepted / name, out / name)
    listing.append(('installer.mp4', 'Accepted complete upgrade wizard, reused without recapture'))
    memory.save(out / 'actions.json', {'actions': capture['actions'], 'sources': capture.get('captureSources', []), 'mouseClicks': sum(a['mouseClick'] for a in capture['actions'])})
    memory.save(out / 'reused-installer-media.json', {'source': str(accepted), 'sourceBinding': accepted_receipt, 'files': {str(p.relative_to(accepted)): memory.identity(p) for p in sorted((accepted / 'installer').glob('*.png')) + [accepted / 'installer.mp4']}, 'homeRetained': str(accepted / 'screens/A-001-home-main.png')})
    memory.save(out / 'media-summary.json', {
        'screenshots': {'installer': len(list(installer.glob('*.png'))), **{key: sum(s['pass'] == key for s in capture['screens']) for key in ['A', 'B', 'C']}},
        'actions': {p: sum(a['pattern'] == p for a in capture['actions']) for p in sorted({a['pattern'] for a in capture['actions']})},
        'mouseClicks': sum(a['mouseClick'] for a in capture['actions']),
        'notCaptured': capture['notCaptured'], 'holdSeconds': hold,
        'videos': {name: {**memory.identity(out / (name + '.mp4')), 'durationSeconds': float(json.loads((out / (name + '-video.json')).read_text())['format']['duration'])} for name in ['tour', 'installer']}})
    # Raw frames remain in their verified archive.
    shutil.rmtree(out / 'encoding-frames')
    for name in ['tour']:
        for segment in capture['movies'][name].get('segments', [dict(capture['movies'][name], evidenceRoot=str(extracted))]):
            relative = segment['folder'].split('\\tour\\', 1)[1]
            folder = Path(segment['evidenceRoot']) / 'tour' / relative.replace('\\', '/')
            shutil.rmtree(folder)
    lines = ['# Roo Industries Optimization Suite ' + capture['version'] + ' tour', '',
             'The installer upgrades published 0.11.0. Pass A uses the original theme in Simple mode; B uses advanced mode; C uses Blackout Gold in advanced mode. App images contain only their 1600×1000 DWM frame bounds.', '',
             'The accepted installer clip and first Home shot are retained separately; reused-installer-media.json binds those files to their original receipt. This run silently upgrades the candidate over 0.11.0 before the UIA-only app tour.', '', '## Media', '']
    lines += ['- [' + path + '](' + path + '): ' + description for path, description in listing]
    lines += ['', '## Not captured', ''] + ['- ' + str(item.get('pass', 'All')) + ': ' + item['state'] + '. ' + item['reason'] for item in capture['notCaptured']]
    lines += ['', '## Evidence', '', 'The nonce-bound capture receipt and actions.json contain every exact target identity, cursor position, UIA pattern/result, DWM bound and screenshot hash. Raw 15 fps window frames and UIA trees are retained in evidence.zip. cleanup-audit.json records published-build, file-data and raw-registry restoration.']
    for path in sorted(out.rglob('*')):
        if path.is_file() and path.relative_to(out).as_posix() not in {p for p, _ in listing} and path.name != 'index.md':
            lines.append('- [' + path.relative_to(out).as_posix() + '](' + path.relative_to(out).as_posix() + '): ' + ('UIA tree or raw capture provenance' if path.is_relative_to(extracted) else 'Run evidence'))
    (out / 'index.md').write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scenario', choices=['full'], required=True)
    parser.add_argument('--host', required=True)
    parser.add_argument('--expected-machine', required=True)
    parser.add_argument('--installer', type=Path, required=True)
    parser.add_argument('--installer-media', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--restore-installer', type=Path, required=True)
    parser.add_argument('--restore-sha256', required=True)
    parser.add_argument('--passes', nargs='+', choices=['A', 'B', 'C'], default=['A', 'B', 'C'])
    parser.add_argument('--completed-capture', type=Path)
    parser.add_argument('--hold-seconds', type=int, default=4, choices=[3, 4])
    parser.add_argument('--out-dir', type=Path, required=True)
    args = parser.parse_args()
    prior = None
    if args.completed_capture:
        prior = json.loads(args.completed_capture.read_text())
        if prior['version'] != args.version or prior['candidateSha256'].lower() != args.sha256.lower():
            parser.error('Completed capture has a different candidate')
        if set(args.passes) & {s['pass'] for s in prior['screens']}:
            parser.error('Completed and requested passes overlap')
        for shot in prior['screens']:
            matches = list(Path(shot['evidenceRoot']).rglob(shot['file']))
            if len(matches) != 1 or memory.identity(matches[0])['sha256'].upper() != shot['sha256']:
                parser.error('Completed screenshot identity differs')
        for source in prior['captureSources']:
            if memory.identity(Path(source['receipt']))['sha256'].lower() != source['sha256'].lower():
                parser.error('Completed receipt identity differs')
        if any(a['mouseClick'] or a['result'] != 'success' for a in prior['actions']):
            parser.error('Completed capture contains a failed or clicked action')
        if set(args.passes) | {s['pass'] for s in prior['screens']} != {'A', 'B', 'C'}:
            parser.error('Completed and requested captures must cover all passes')
    elif args.passes != ['A', 'B', 'C']:
        parser.error('Partial passes require --completed-capture')
    for path, expected in [(args.installer, args.sha256), (args.restore_installer, args.restore_sha256)]:
        if memory.identity(path)['sha256'].lower() != expected.lower():
            parser.error('Installer SHA-256 differs; no remote action started')
    accepted = json.loads((args.installer_media / 'source-binding.json').read_text())
    if accepted['candidate'] != memory.identity(args.installer):
        parser.error('Accepted installer media belongs to different installer bytes')
    for name in ['installer.mp4', 'installer-video.json', 'screens/A-001-home-main.png']:
        if not (args.installer_media / name).is_file():
            parser.error('Accepted media is missing: ' + name)
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip():
        parser.error('Commit the scripts first; stage a clean head')
    load('tour_lint', ROOT / 'tools/validation/Update/run_harness_checks.py').lint_tree(ROOT / 'tools/validation/Tour')
    args.out_dir.mkdir(parents=True, exist_ok=False)
    memory.save(args.out_dir / 'source-binding.json', {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                                                    'candidate': memory.identity(args.installer), 'restore': memory.identity(args.restore_installer)})
    result = Tour(args).run()
    if (args.out_dir / 'capture.json').exists():
        try:
            capture = json.loads((args.out_dir / 'capture.json').read_text())
            if prior:
                capture['screens'] = prior['screens'] + capture['screens']
                capture['actions'] = prior['actions'] + capture['actions']
                capture['notCaptured'] = prior['notCaptured'] + capture['notCaptured']
                capture['movies']['tour'] = {'segments': prior['movies']['tour']['segments'] + [dict(capture['movies']['tour'], evidenceRoot=str(args.out_dir / 'evidence'))]}
                capture['captureSources'] = prior['captureSources'] + [{'head': json.loads((args.out_dir / 'source-binding.json').read_text())['head'], 'receipt': str(args.out_dir / 'capture.json')}]
                memory.save(args.out_dir / 'capture.json', capture)
            encode(args.out_dir, capture, args.hold_seconds, args.installer_media)
        except Exception as error:
            result['status'] = 'fail'
            result['encodingFailure'] = memory.describe_error(error)
            memory.save(args.out_dir / 'receipt.json', result)
    print(json.dumps(result, indent=2))
    if result['status'] != 'pass':
        raise SystemExit(1)


if __name__ == '__main__':
    main()
