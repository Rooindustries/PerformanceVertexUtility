import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description='Dry-run publish and set-feed against the live signed feed (GET only), then publish and roll back against a local HTTPS fixture; fake vercel commands keep every upload on this machine.')
parser.add_argument('--published-installer', type=Path)
parser.add_argument('--local-only', action='store_true', help='Run only the rolled-back feed cases against a local HTTPS fixture.')
parser.add_argument('--tool', type=Path, default=root / 'tools/release/publish_update.py')
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
if not args.local_only and not args.published_installer:
    parser.error('--published-installer is required unless --local-only is set')
feed = (root / 'tools/release/update-feed.txt').read_text().strip()
work = Path(tempfile.mkdtemp(prefix='publish-guard-', dir=os.environ.get('TMPDIR')))
rows = []
server = None
try:
    key = ec.generate_private_key(ec.SECP256R1())
    key_id = 'test' + secrets.token_hex(6)
    keys = json.loads((root / 'tools/release/update-keys.json').read_text())
    keys[key_id] = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).decode()
    fake = work / 'bin'
    fake.mkdir()
    (fake / 'vercel').write_text('#!/bin/sh\necho "$@" >> "' + str(work / 'vercel-calls.txt') + '"\nexit 1\n')
    (fake / 'vercel').chmod(0o755)
    env = dict(os.environ, BLOB_READ_WRITE_TOKEN='publish-guard-fixture', PATH=str(fake) + os.pathsep + os.environ.get('PATH', ''))
    dummy = work / 'dummy-setup.exe'
    dummy.write_bytes(secrets.token_bytes(1048576))
    dummy_identity = {'size': dummy.stat().st_size, 'sha256': hashlib.sha256(dummy.read_bytes()).hexdigest()}

    def tool_tree(name, feed_text, released):
        tree = work / name
        (tree / 'tools/release').mkdir(parents=True)
        (tree / 'backend/native/Optimizer.Core').mkdir(parents=True)
        shutil.copy(args.tool, tree / 'tools/release/publish_update.py')
        (tree / 'tools/release/update-feed.txt').write_text(feed_text)
        (tree / 'tools/release/released-versions.txt').write_bytes(released)
        shutil.copy(root / 'backend/native/Optimizer.Core/Optimizer.Core.csproj', tree / 'backend/native/Optimizer.Core/Optimizer.Core.csproj')
        (tree / 'tools/release/update-keys.json').write_text(json.dumps(keys))
        return tree / 'tools/release/publish_update.py'

    def signed(name, version, installer):
        payload = {'schemaVersion': 1, 'product': 'RooIndustries.OptimizationSuite', 'channel': 'beta', 'version': version, 'publishedAtUtc': datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'), 'installer': installer, 'notes': 'Publish guard fixture.'}
        data = json.dumps(payload, separators=(',', ':')).encode()
        path = work / (name + '.json')
        path.write_text(json.dumps({'schemaVersion': 1, 'keyId': key_id, 'payload': base64.b64encode(data).decode(), 'signature': base64.b64encode(key.sign(data, ec.ECDSA(hashes.SHA256()))).decode()}, separators=(',', ':')) + '\n')
        return path

    def fixture_url(version, origin):
        return origin + '/b/' + secrets.token_urlsafe(24) + '/RooIndustries-OptimizationSuite-' + version + '-setup.exe'

    def run(name, tool, arguments, code, text, after=lambda: None, run_env=env, uploads=False):
        result = subprocess.run([sys.executable, '-I', str(tool)] + arguments, capture_output=True, text=True, env=run_env, cwd=work, timeout=600)
        output = result.stdout + result.stderr
        problem = None if result.returncode == code and text in output else 'unexpected exit code or output'
        problem = problem or ('a refused command printed an upload command' if code and not uploads and 'vercel blob put' in output else None)
        problem = problem or ('the tool stopped with a traceback' if 'Traceback (most recent call last)' in output else None)
        problem = problem or after()
        rows.append({'case': name, 'passed': problem is None, 'problem': problem, 'exitCode': result.returncode, 'expectedExitCode': code, 'expectedText': text, 'output': output})
        print(('PASS ' if problem is None else 'FAIL ') + name + ('' if problem is None else ': ' + problem))
        return result

    def publish_case(name, tool, version, code, text, live, path, origin, run_env, extra=(), after=lambda: None):
        url = fixture_url(version, origin)
        manifest = signed(name, version, {'url': url, **dummy_identity})
        rollback = manifest.with_name(manifest.stem + '.previous-live.json')
        def kept():
            if code == 0 and (not rollback.exists() or rollback.read_bytes() != live):
                return 'rollback copy differs from the live manifest'
            if code != 0 and rollback.exists():
                return 'a refused publish wrote a rollback copy'
            return after()
        run(name, tool, ['publish', '--installer', str(dummy), '--manifest', str(manifest), '--installer-path', urlparse(url).path[1:], '--feed-path', path] + list(extra), code, text, kept, run_env)

    def precedence(version):
        core, _, prerelease = version.split('+')[0].partition('-')
        parts = prerelease.split('.') if prerelease else []
        return [int(n) for n in core.split('.')], not parts, [(0, int(p), '') if p.isdecimal() else (1, 0, p) for p in parts]

    def live_cases(prefix, tool, live, installer, live_feed, run_env):
        path = urlparse(live_feed).path[1:]
        origin = 'https://' + urlparse(live_feed).netloc
        (work / (prefix + 'live.json')).write_bytes(live)
        verified = run(prefix + 'live-feed-verified', tool, ['verify', '--manifest', str(work / (prefix + 'live.json')), '--feed-url', live_feed], 0, '"verified": true', run_env=run_env)
        if verified.returncode:
            return
        live_payload = json.loads(verified.stdout)
        live_version = live_payload['version']
        lines = [line.strip() for line in (tool.parent / 'released-versions.txt').read_text(encoding='utf-8-sig').splitlines()]
        floor = max([live_version] + [line for line in lines if line and not line.startswith('#')], key=precedence)
        newest = ('the live beta ' if floor == live_version else 'the released version ') + floor
        core, _, prerelease = floor.split('+')[0].partition('-')
        suffix = '-' + prerelease if prerelease else ''
        numbers = [int(n) for n in core.split('.')]
        older = numbers[:]
        older[max(i for i, n in enumerate(older) if n)] -= 1
        cases = [
            ('older-version-refused', '.'.join(map(str, older)) + suffix, 1, 'is not newer than ' + newest),
            ('lower-prerelease-refused', core + '-alpha', 1, 'is not newer than ' + newest),
            ('next-patch-accepted', '.'.join(map(str, numbers[:2] + [numbers[2] + 1])) + suffix, 0, 'Dry run: nothing uploaded.'),
        ]
        if prerelease:
            cases += [('longer-prerelease-accepted', core + suffix + '.1', 0, 'Dry run: nothing uploaded.'), ('release-over-prerelease-accepted', core, 0, 'Dry run: nothing uploaded.')]
        run(prefix + 'equal-live-version-refused', tool, ['publish', '--installer', str(installer), '--manifest', str(work / (prefix + 'live.json')), '--installer-path', urlparse(live_payload['installer']['url']).path[1:], '--feed-path', path], 1, 'is not newer than ' + newest, run_env=run_env)
        for name, version, code, text in cases:
            publish_case(prefix + name, tool, version, code, text, live, path, origin, run_env)
        run(prefix + 'set-feed-same-as-live-refused', tool, ['set-feed', '--manifest', str(work / (prefix + 'live.json')), '--feed-path', path], 1, 'The live feed already serves this manifest', run_env=run_env)
        run(prefix + 'set-feed-missing-installer-refused', tool, ['set-feed', '--manifest', str(signed(prefix + 'missing', live_version, {'url': fixture_url(live_version, origin), **dummy_identity})), '--feed-path', path], 1, 'HTTP Error 404', run_env=run_env)
        run(prefix + 'set-feed-wrong-path-refused', tool, ['set-feed', '--manifest', str(work / (prefix + 'live.json')), '--feed-path', 'u/' + secrets.token_urlsafe(24) + '/beta.json'], 1, 'Feed path differs from the committed feed', run_env=run_env)
        run(prefix + 'set-feed-rollback-dry-run', tool, ['set-feed', '--manifest', str(signed(prefix + 'rollback', live_version, live_payload['installer'])), '--feed-path', path], 0, 'Replacing the live ' + live_version + ' manifest with version ' + live_version + '.', run_env=run_env)

    if not args.local_only:
        with urlopen(Request(feed + '?t=' + str(int(datetime.now(timezone.utc).timestamp())), headers={'Cache-Control': 'no-cache'}), timeout=20) as response:
            live = response.read(65537)
        live_cases('', tool_tree('tree', (root / 'tools/release/update-feed.txt').read_text(), (root / 'tools/release/released-versions.txt').read_bytes()), live, args.published_installer, feed, env)

    tls = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'publish-guard-fixture')])
    now = datetime.now(timezone.utc)
    certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(tls.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(hours=1))
                   .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
                   .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
                   .add_extension(x509.SubjectKeyIdentifier.from_public_key(tls.public_key()), critical=False)
                   .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(tls.public_key()), critical=False)
                   .sign(tls, hashes.SHA256()))
    (work / 'fixture-cert.pem').write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    (work / 'fixture-key.pem').write_bytes(tls.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(work / 'fixture-cert.pem', work / 'fixture-key.pem')
    served = {}
    failures = {}
    lagging = {}
    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlparse(self.path).path
            if lagging.get(path) and lagging[path][1]:
                lagging[path][1] -= 1
                self.send_response(200)
                self.send_header('Content-Length', str(len(lagging[path][0])))
                self.end_headers()
                self.wfile.write(lagging[path][0])
                return
            if failures.get(path):
                status = failures[path].pop(0)
                if status in ('truncated', 'oversize'):
                    body = (work / 'blob' / path[1:]).read_bytes() + (b' ' * 65536 if status == 'oversize' else b'')
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body[:len(body) // 2] if status == 'truncated' else body)
                elif status:
                    self.send_error(status)
                return
            blob = work / 'blob' / path[1:]
            body = served.get(path, blob.read_bytes() if blob.is_file() else None)
            if body is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *unused):
            pass
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    fixture.socket = context.wrap_socket(fixture.socket, server_side=True)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    server = fixture
    origin = 'https://127.0.0.1:' + str(server.server_address[1])
    local_env = {name: value for name, value in env.items() if not name.lower().endswith('_proxy')}
    local_env['SSL_CERT_FILE'] = str(work / 'fixture-cert.pem')
    for state, live_version, listed in [
        ('live-0.11.0-beta-', '0.11.0-beta', b'0.9.0-beta\n0.10.0-beta\n0.11.0-beta\n'),
        ('live-0.11.1-beta-unlisted-', '0.11.1-beta', b'0.9.0-beta\n0.10.0-beta\n0.11.0-beta\n'),
        ('live-0.11.1-beta-listed-', '0.11.1-beta', b'0.9.0-beta\n0.10.0-beta\n0.11.0-beta\n0.11.1-beta\n'),
        ('live-0.11.0-beta-after-rollback-', '0.11.0-beta', b'0.9.0-beta\n0.10.0-beta\n0.11.0-beta\n0.11.1-beta\n'),
    ]:
        state_feed = origin + '/u/' + secrets.token_urlsafe(12) + '/beta.json'
        live_url = fixture_url(live_version, origin)
        live = signed(state + 'feed', live_version, {'url': live_url, **dummy_identity}).read_bytes()
        served[urlparse(live_url).path] = dummy.read_bytes()
        served[urlparse(state_feed).path] = live
        live_cases(state, tool_tree(state + 'tree', state_feed + '\n', listed), live, dummy, state_feed, local_env)
    local_feed_path = 'u/fixture/beta.json'
    released = '\ufeff0.9.0-beta\n0.11.0-beta \n\n# The feed was rolled back to 0.10.0-beta\n0.10.0-beta\n'.encode('utf-8')
    tool = tool_tree('rolled-back-tree', origin + '/' + local_feed_path + '\n', released)
    rolled_back = signed('rolled-back-live', '0.10.0-beta', {'url': fixture_url('0.10.0-beta', origin), **dummy_identity}).read_bytes()
    served['/' + local_feed_path] = rolled_back
    for name, version, code, text in [
        ('rolled-back-older-than-released-refused', '0.10.9-beta', 1, 'is not newer than the released version 0.11.0-beta, so testers who already have 0.11.0-beta would not be offered it'),
        ('rolled-back-equal-to-released-refused', '0.11.0-beta', 1, 'is not newer than the released version 0.11.0-beta, so testers who already have 0.11.0-beta would not be offered it'),
        ('rolled-back-newer-than-released-accepted', '0.11.1-beta', 0, 'Dry run: nothing uploaded.'),
    ]:
        publish_case(name, tool, version, code, text, rolled_back, local_feed_path, origin, local_env)
    released_list = tool.parent / 'released-versions.txt'
    released_list.write_text('0.9.0-beta\nnot-a-version\n')
    publish_case('released-list-malformed-refused', tool, '0.11.1-beta', 1, 'Invalid SemVer release version', rolled_back, local_feed_path, origin, local_env)
    released_list.unlink()
    publish_case('released-list-missing-refused', tool, '0.11.1-beta', 1, 'released-versions.txt', rolled_back, local_feed_path, origin, local_env)
    released_list.write_bytes(released)
    below = fixture_url('0.9.0-beta', origin)
    served[urlparse(below).path] = dummy.read_bytes()
    run('set-feed-below-released-dry-run', tool, ['set-feed', '--manifest', str(signed('below-released', '0.9.0-beta', {'url': below, **dummy_identity})), '--feed-path', local_feed_path], 0, 'Replacing the live 0.10.0-beta manifest with version 0.9.0-beta.', run_env=local_env)
    blob_bin = work / 'blob-bin'
    blob_bin.mkdir()
    (blob_bin / 'vercel').write_text('#!/bin/sh\nfile=$3\nwhile [ $# -gt 1 ]; do\n  [ "$1" = --pathname ] && target="' + str(work / 'blob') + '/$2"\n  shift\ndone\nmkdir -p "$(dirname "$target")" && cp "$file" "$target"\n')
    (blob_bin / 'vercel').chmod(0o755)
    upload_env = dict(local_env, PATH=str(blob_bin) + os.pathsep + local_env['PATH'])
    for flow, listed_first in [('listed-then-rolled-back', True), ('rolled-back-before-listed', False)]:
        flow_path = 'u/' + flow + '/beta.json'
        tool = tool_tree(flow + '-tree', origin + '/' + flow_path + '\n', b'0.9.0-beta\n0.10.0-beta\n0.11.0-beta')
        released_list = tool.parent / 'released-versions.txt'
        before = released_list.read_bytes()
        previous_url = fixture_url('0.11.0-beta', origin)
        previous = signed(flow + '-previous', '0.11.0-beta', {'url': previous_url, **dummy_identity})
        for blob_path, source in [(urlparse(previous_url).path[1:], dummy), (flow_path, previous)]:
            (work / 'blob' / blob_path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(source, work / 'blob' / blob_path)
        bad_url = fixture_url('0.11.1-beta', origin)
        bad = signed(flow + '-bad', '0.11.1-beta', {'url': bad_url, **dummy_identity})
        def listed():
            if released_list.read_bytes() != before + b'\n0.11.1-beta\n':
                return 'the verified publish did not add 0.11.1-beta to released-versions.txt once, keeping the other lines'
        run(flow + '-publish-adds-released-version', tool, ['publish', '--installer', str(dummy), '--manifest', str(bad), '--installer-path', urlparse(bad_url).path[1:], '--feed-path', flow_path, '--yes-publish'], 0, 'Commit that line to main', listed, upload_env)
        rollback = ['set-feed', '--manifest', str(bad.with_name(bad.stem + '.previous-live.json')), '--feed-path', flow_path, '--yes-publish']
        if not listed_first:
            released_list.write_bytes(before)
            previous_installer = urlparse(previous_url).path
            failures[previous_installer] = [503]
            def still_live():
                if failures[previous_installer] != [503]:
                    return 'the installer was downloaded before the refusal'
                if (work / 'blob' / flow_path).read_bytes() != bad.read_bytes():
                    return 'the refused rollback changed the feed'
            for failure, status, reason in [('503', 503, ''), ('dropped', 0, ''), ('truncated', 'truncated', 'Published response ended early')]:
                failures['/' + flow_path] = [status]
                run(flow + '-feed-' + failure + '-rollback-refused', tool, rollback, 1, "Couldn't read the live feed (" + reason, lambda: 'the feed failure was not served' if failures['/' + flow_path] else still_live(), upload_env)
            run(flow + '-unlisted-rollback-refused', tool, rollback, 1, 'The live beta 0.11.1-beta is not in released-versions.txt. Add it there before rolling back', still_live, upload_env)
            for failure, status in [('503', 503), ('dropped', 0), ('truncated', 'truncated'), ('oversize', 'oversize'), ('no-content', 204)]:
                failures['/' + flow_path] = [status]
                publish_case(flow + '-feed-' + failure + '-publish-refused', tool, '0.11.2-beta', 1, 'Update release refused: ', bad.read_bytes(), flow_path, origin, upload_env, ['--yes-publish'], lambda: 'the feed failure was not served' if failures['/' + flow_path] else still_live())
            failures[previous_installer] = []
            for version in ['0.11.1-beta', '0.11.1-alpha']:
                publish_case(flow + '-live-' + version + '-refused', tool, version, 1, 'is not newer than the live beta 0.11.1-beta', bad.read_bytes(), flow_path, origin, local_env, ['--yes-publish'])
            released_list.write_bytes(before + b'\n0.11.1-beta\n')
        run(flow + '-rollback', tool, rollback, 0, 'The feed now serves version 0.11.0-beta, verified over HTTPS.', run_env=upload_env)
        for version in ['0.11.1-beta', '0.11.1-alpha']:
            publish_case(flow + '-republish-' + version + '-refused', tool, version, 1, 'is not newer than the released version 0.11.1-beta, so testers who already have 0.11.1-beta would not be offered it', previous.read_bytes(), flow_path, origin, local_env, ['--yes-publish'])
        publish_case(flow + '-newer-accepted', tool, '0.11.2-beta', 0, 'Dry run: nothing uploaded.', previous.read_bytes(), flow_path, origin, local_env)
    repair_path = 'u/repair/beta.json'
    tool = tool_tree('repair-tree', origin + '/' + repair_path + '\n', b'0.11.0-beta\n')
    released_list = tool.parent / 'released-versions.txt'
    repair_url = fixture_url('0.11.0-beta', origin)
    served[urlparse(repair_url).path] = dummy.read_bytes()
    repair = signed('repair', '0.11.0-beta', {'url': repair_url, **dummy_identity})
    def serves(manifest):
        return lambda: None if (work / 'blob' / repair_path).read_bytes() == manifest.read_bytes() else 'the feed does not serve the uploaded manifest'
    set_repair = ['set-feed', '--manifest', str(repair), '--feed-path', repair_path, '--yes-publish']
    run('set-feed-missing-feed-repaired', tool, set_repair, 0, 'does not verify (HTTP Error 404', serves(repair), upload_env)
    envelope = json.loads(repair.read_bytes())
    envelope['signature'] = json.loads(signed('repair-other', '0.11.1-beta', {'url': repair_url, **dummy_identity}).read_bytes())['signature']
    (work / 'blob' / repair_path).write_text(json.dumps(envelope))
    run('set-feed-bad-signature-feed-repaired', tool, set_repair, 0, 'does not verify (Invalid signature)', serves(repair), upload_env)
    for failure, status, reason in [('oversize', 'oversize', 'Published response exceeds its bound'), ('no-content', 204, 'Published URL did not return HTTPS HTTP 200')]:
        replacement = signed('repair-' + failure, '0.11.0-beta', {'url': repair_url, **dummy_identity})
        failures['/' + repair_path] = [status]
        run('set-feed-' + failure + '-feed-repaired', tool, ['set-feed', '--manifest', str(replacement), '--feed-path', repair_path, '--yes-publish'], 0, 'does not verify (' + reason + ')', lambda: 'the feed failure was not served' if failures['/' + repair_path] else serves(replacement)(), upload_env)
    late_url = fixture_url('0.11.1-beta', origin)
    late = signed('late', '0.11.1-beta', {'url': late_url, **dummy_identity})
    released_list.chmod(0o444)
    def unlisted():
        return serves(late)() or (None if released_list.read_bytes() == b'0.11.0-beta\n' else 'the read-only list changed')
    run('publish-list-write-failure-reported', tool, ['publish', '--installer', str(dummy), '--manifest', str(late), '--installer-path', urlparse(late_url).path[1:], '--feed-path', repair_path, '--yes-publish'], 1, "Published, but couldn't add 0.11.1-beta to released-versions.txt", unlisted, upload_env, True)
    # Vercel can serve the old feed for up to a minute after an overwrite; the tool must wait for the new bytes.
    lag_path = 'u/lagging/beta.json'
    tool = tool_tree('lagging-tree', origin + '/' + lag_path + '\n', b'0.11.0-beta\n')
    lag_old_url = fixture_url('0.11.0-beta', origin)
    served[urlparse(lag_old_url).path] = dummy.read_bytes()
    lag_old = signed('lagging-old', '0.11.0-beta', {'url': lag_old_url, **dummy_identity})
    (work / 'blob' / lag_path).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(lag_old, work / 'blob' / lag_path)
    lag_new_url = fixture_url('0.11.1-beta', origin)
    lag_new = signed('lagging-new', '0.11.1-beta', {'url': lag_new_url, **dummy_identity})
    def caught_up(manifest):
        return lambda: 'the tool stopped before the feed caught up' if lagging['/' + lag_path][1] or (work / 'blob' / lag_path).read_bytes() != manifest.read_bytes() else None
    lagging['/' + lag_path] = [lag_old.read_bytes(), 3]
    run('publish-waits-for-the-feed-to-update', tool, ['publish', '--installer', str(dummy), '--manifest', str(lag_new), '--installer-path', urlparse(lag_new_url).path[1:], '--feed-path', lag_path, '--yes-publish'], 0, 'Published manifest and installer verified over HTTPS.', caught_up(lag_new), upload_env)
    lag_rollback = lag_new.with_name(lag_new.stem + '.previous-live.json')
    lagging['/' + lag_path] = [lag_new.read_bytes(), 3]
    run('set-feed-waits-for-the-feed-to-update', tool, ['set-feed', '--manifest', str(lag_rollback), '--feed-path', lag_path, '--yes-publish'], 0, 'The feed now serves version 0.11.0-beta, verified over HTTPS.', caught_up(lag_rollback), upload_env)
    lag_newer_url = fixture_url('0.11.2-beta', origin)
    lag_newer = signed('lagging-newer', '0.11.2-beta', {'url': lag_newer_url, **dummy_identity})
    lagging['/' + lag_path] = [lag_rollback.read_bytes(), 1000000]
    lag_list = tool.parent / 'released-versions.txt'
    run('publish-refused-when-the-feed-never-updates', tool, ['publish', '--installer', str(dummy), '--manifest', str(lag_newer), '--installer-path', urlparse(lag_newer_url).path[1:], '--feed-path', lag_path, '--yes-publish'], 1, 'Published feed still serves other bytes 90 seconds after the upload', lambda: '0.11.2-beta was listed though the feed never served it' if '0.11.2-beta' in lag_list.read_text() else None, upload_env, uploads=True)
    lagging.clear()
    uploads = (work / 'vercel-calls.txt').read_text().splitlines() if (work / 'vercel-calls.txt').exists() else []
    rows.append({'case': 'no-upload-attempted', 'passed': not uploads, 'calls': uploads})
    print(('PASS ' if not uploads else 'FAIL ') + 'no-upload-attempted')
finally:
    if server:
        server.shutdown()
        server.server_close()
    shutil.rmtree(work, ignore_errors=True)
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps({'tool': str(args.tool), 'feed': feed, 'localOnly': args.local_only, 'uploads': 0, 'cases': rows, 'passed': all(row['passed'] for row in rows)}, indent=2))
sys.exit(0 if rows and all(row['passed'] for row in rows) else 1)
