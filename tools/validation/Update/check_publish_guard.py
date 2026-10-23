import argparse
import base64
import hashlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description='Dry-run publish and set-feed against the live signed feed (GET only); a fake vercel proves nothing is uploaded.')
parser.add_argument('--published-installer', type=Path, required=True)
parser.add_argument('--tool', type=Path, default=root / 'tools/release/publish_update.py')
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
feed = (root / 'tools/release/update-feed.txt').read_text().strip()
feed_path = urlparse(feed).path[1:]
host = urlparse(feed).hostname
work = Path(tempfile.mkdtemp(prefix='publish-guard-', dir=os.environ.get('TMPDIR')))
rows = []
try:
    with urlopen(Request(feed + '?t=' + str(int(datetime.now(timezone.utc).timestamp())), headers={'Cache-Control': 'no-cache'}), timeout=20) as response:
        live = response.read(65537)
    (work / 'live.json').write_bytes(live)
    live_payload = json.loads(base64.b64decode(json.loads(live)['payload']))
    live_installer = live_payload['installer']

    tree = work / 'tree'
    (tree / 'tools/release').mkdir(parents=True)
    (tree / 'backend/native/Optimizer.Core').mkdir(parents=True)
    shutil.copy(args.tool, tree / 'tools/release/publish_update.py')
    shutil.copy(root / 'tools/release/update-feed.txt', tree / 'tools/release/update-feed.txt')
    shutil.copy(root / 'backend/native/Optimizer.Core/Optimizer.Core.csproj', tree / 'backend/native/Optimizer.Core/Optimizer.Core.csproj')
    key = ec.generate_private_key(ec.SECP256R1())
    key_id = 'test' + secrets.token_hex(6)
    keys = json.loads((root / 'tools/release/update-keys.json').read_text())
    keys[key_id] = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).decode()
    (tree / 'tools/release/update-keys.json').write_text(json.dumps(keys))
    fake = work / 'bin'
    fake.mkdir()
    (fake / 'vercel').write_text('#!/bin/sh\necho "$@" >> "' + str(work / 'vercel-calls.txt') + '"\nexit 1\n')
    (fake / 'vercel').chmod(0o755)
    env = {name: value for name, value in os.environ.items() if name != 'BLOB_READ_WRITE_TOKEN'}
    env['PATH'] = str(fake) + os.pathsep + env.get('PATH', '')
    dummy = work / 'dummy-setup.exe'
    dummy.write_bytes(secrets.token_bytes(1048576))
    dummy_identity = {'size': dummy.stat().st_size, 'sha256': hashlib.sha256(dummy.read_bytes()).hexdigest()}

    def signed(name, version, installer):
        payload = {'schemaVersion': 1, 'product': 'RooIndustries.OptimizationSuite', 'channel': 'beta', 'version': version, 'publishedAtUtc': datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'), 'installer': installer, 'notes': 'Publish guard fixture.'}
        data = json.dumps(payload, separators=(',', ':')).encode()
        path = work / (name + '.json')
        path.write_text(json.dumps({'schemaVersion': 1, 'keyId': key_id, 'payload': base64.b64encode(data).decode(), 'signature': base64.b64encode(key.sign(data, ec.ECDSA(hashes.SHA256()))).decode()}, separators=(',', ':')) + '\n')
        return path

    def fixture_url(version):
        return 'https://' + host + '/b/' + secrets.token_urlsafe(24) + '/RooIndustries-OptimizationSuite-' + version + '-setup.exe'

    def run(name, tool, arguments, code, text, after=lambda: None):
        result = subprocess.run([sys.executable, '-I', str(tool)] + arguments, capture_output=True, text=True, env=env, cwd=work, timeout=600)
        output = result.stdout + result.stderr
        problem = None if result.returncode == code and text in output else 'unexpected exit code or output'
        problem = problem or after()
        rows.append({'case': name, 'passed': problem is None, 'problem': problem, 'exitCode': result.returncode, 'expectedExitCode': code, 'expectedText': text, 'output': output})
        print(('PASS ' if problem is None else 'FAIL ') + name + ('' if problem is None else ': ' + problem))

    tool = tree / 'tools/release/publish_update.py'
    run('equal-live-version-refused', tool, ['publish', '--installer', str(args.published_installer), '--manifest', str(work / 'live.json'), '--installer-path', urlparse(live_installer['url']).path[1:], '--feed-path', feed_path], 1, 'is not newer than the live beta ' + live_payload['version'])
    for name, version, code, text in [
        ('older-version-refused', '0.10.9-beta', 1, 'is not newer than the live beta'),
        ('lower-prerelease-refused', '0.11.0-alpha', 1, 'is not newer than the live beta'),
        ('longer-prerelease-accepted', '0.11.0-beta.1', 0, 'Dry run: nothing uploaded.'),
        ('release-over-prerelease-accepted', '0.11.0', 0, 'Dry run: nothing uploaded.'),
        ('next-patch-accepted', '0.11.1-beta', 0, 'Dry run: nothing uploaded.'),
    ]:
        url = fixture_url(version)
        manifest = signed(name, version, {'url': url, **dummy_identity})
        rollback = manifest.with_name(manifest.stem + '.previous-live.json')
        def kept(rollback=rollback, accepted=code == 0):
            if accepted and (not rollback.exists() or rollback.read_bytes() != live):
                return 'rollback copy differs from the live manifest'
            if not accepted and rollback.exists():
                return 'a refused publish wrote a rollback copy'
        run(name, tool, ['publish', '--installer', str(dummy), '--manifest', str(manifest), '--installer-path', urlparse(url).path[1:], '--feed-path', feed_path], code, text, kept)
    run('set-feed-same-as-live-refused', tool, ['set-feed', '--manifest', str(work / 'live.json'), '--feed-path', feed_path], 1, 'The live feed already serves this manifest')
    run('set-feed-missing-installer-refused', tool, ['set-feed', '--manifest', str(signed('missing', '0.11.1-beta', {'url': fixture_url('0.11.1-beta'), **dummy_identity})), '--feed-path', feed_path], 1, 'HTTP Error 404')
    run('set-feed-wrong-path-refused', tool, ['set-feed', '--manifest', str(work / 'live.json'), '--feed-path', 'u/' + secrets.token_urlsafe(24) + '/beta.json'], 1, 'Feed path differs from the committed feed')
    run('set-feed-rollback-dry-run', tool, ['set-feed', '--manifest', str(signed('rollback', live_payload['version'], live_installer)), '--feed-path', feed_path], 0, 'Replacing the live ' + live_payload['version'] + ' manifest with version ' + live_payload['version'] + '.')
    uploads = (work / 'vercel-calls.txt').read_text().splitlines() if (work / 'vercel-calls.txt').exists() else []
    rows.append({'case': 'no-upload-attempted', 'passed': not uploads, 'calls': uploads})
    print(('PASS ' if not uploads else 'FAIL ') + 'no-upload-attempted')
finally:
    shutil.rmtree(work, ignore_errors=True)
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps({'tool': str(args.tool), 'feed': feed, 'uploads': 0, 'cases': rows, 'passed': all(row['passed'] for row in rows)}, indent=2))
sys.exit(0 if rows and all(row['passed'] for row in rows) else 1)
