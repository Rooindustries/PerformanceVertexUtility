import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import signal
import uuid
import time
from urllib.request import urlopen
from urllib.parse import urlsplit, urljoin
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "artifacts/roo-20/ota"
HOST = None
MACHINE = None
FEED = None
KEY = None
VERSION_A = None
VERSION_B = None
FRAME_RECEIPT = None
spec = importlib.util.spec_from_file_location("windows_ssh", ROOT / "tools/validation/windows_ssh.py")
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)


def command(args, log=None):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if log:
        Path(log).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError("Command failed: " + " ".join(str(a) for a in args) + "\n" + result.stdout)
    return result.stdout


def remote(script, name):
    try:
        result = windows.invoke(HOST, MACHINE, script)
    except subprocess.CalledProcessError as error:
        output = (error.stdout or "") + (error.stderr or "")
        (OUT / (name + ".log")).write_text(output)
        raise RuntimeError("Windows command failed: " + name + "\n" + output) from None
    (OUT / (name + ".log")).write_text(result.stdout)
    return result.stdout


def interactive(receipt, script, fields, name, minutes=10):
    start = time.monotonic()
    try:
        result = windows.interactive(HOST, MACHINE, receipt, script, fields, minutes, "RooIndustries_ROO20_OTA_" + name)
        output = result.stdout
    except subprocess.CalledProcessError as error:
        output = (error.stdout or "") + (error.stderr or "")
        (OUT / (name + ".log")).write_text(output)
        raise RuntimeError("Desktop scenario failed: " + name + "\n" + output) from None
    (OUT / (name + ".log")).write_text(output)
    (OUT / (name + "-command.json")).write_text(json.dumps({"script": script, "arguments": fields, "seconds": time.monotonic() - start}, indent=2))
    completed = windows.completion(output)
    if not completed["passed"]:
        raise RuntimeError("Invocation did not complete its cleanup: " + name)
    print(name + " completed", flush=True)
    return completed


def copy_from(remote_path, destination):
    Path(destination).parent.mkdir(parents=True, exist_ok=True)
    command(["scp", HOST + ":" + remote_path.replace("\\", "/"), destination])


def copy_to(local_path, remote_path):
    scope = ". " + windows.ps_literal(FRAME_RECEIPT["stagingPath"] + "/tools/validation/Update/Harness.Common.ps1") + ";Open-HarnessRun " + " ".join(windows.ps_literal(FRAME_RECEIPT[k]) for k in ("runRoot", "frameId", "manifestSha256")) + " " + windows.ps_literal(FRAME_RECEIPT["frameId"]) + ";"
    remote(scope + "if(Test-Path -LiteralPath " + windows.ps_literal(remote_path) + "){throw 'Upload input already exists; retained.'}", "upload-input-guard")
    command(["scp", local_path, HOST + ":" + remote_path.replace("\\", "/")])
    remote(scope + "Register-HarnessFile " + windows.ps_literal(remote_path) + " 'upload-input'|Out-Null", "upload-input-record")


def signed(installer, version, url, output):
    notes = OUT / "release-notes.txt"
    notes.write_text("Roo Industries beta update end-to-end release. Settings, rules and undo data are kept.")
    command([sys.executable, "-I", ROOT / "tools/release/publish_update.py", "manifest", "--installer", installer,
             "--version", version, "--url", url, "--notes-file", notes, "--key", KEY, "--out", output], str(output) + ".log")


def contracts(receipt, builds, pc_out, installer, valid):
    directory = OUT / "contracts"
    directory.mkdir(exist_ok=True)
    envelope = json.loads(valid.read_text())
    payload = json.loads(base64.b64decode(envelope["payload"]))
    private = serialization.load_pem_private_key(KEY.read_bytes(), password=None)
    cases = []
    def add(name, value, expected, signed_payload=False):
        if signed_payload:
            data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
            value = dict(envelope, payload=base64.b64encode(data).decode(), signature=base64.b64encode(private.sign(data, ec.ECDSA(hashes.SHA256()))).decode())
        path = directory / (name + ".json")
        path.write_bytes(value if isinstance(value, bytes) else json.dumps(value).encode())
        cases.append((name, path, expected))
    add("valid", envelope, 2)
    add("bad-signature", json.loads((OUT / "bad-signature.json").read_text()), 0)
    add("same", json.loads((OUT / "same.json").read_text()), 1)
    add("older", json.loads((OUT / "older.json").read_text()), 1)
    add("malformed", b"{", 0)
    add("oversized", b" " * 65537, 0)
    add("envelope-schema", dict(envelope, schemaVersion=2), 0)
    add("unknown-key", dict(envelope, keyId="unknown"), 0)
    add("invalid-base64", dict(envelope, payload="%%"), 0)
    add("missing-signature", {key: value for key, value in envelope.items() if key != "signature"}, 0)
    add("duplicate-envelope", valid.read_bytes().rstrip()[:-1] + b',"schemaVersion":1}', 0)
    for name, field, value in [("payload-schema", "schemaVersion", 2), ("wrong-product", "product", "other"),
                               ("wrong-channel", "channel", "stable"), ("bad-version", "version", "0.11"),
                               ("bad-publication", "publishedAtUtc", "yesterday")]:
        add(name, dict(payload, **{field: value}), 0, True)
    for name, field, value in [("http-installer", "url", urljoin(FEED, "setup.exe").replace("https:", "http:", 1)),
                               ("different-host", "url", "https://example.com/setup.exe"), ("undersized", "size", 1048575),
                               ("oversized-installer", "size", 1073741825), ("bad-hash", "sha256", "g" * 64),
                               ("short-hash", "sha256", "a" * 63)]:
        add(name, dict(payload, installer=dict(payload["installer"], **{field: value})), 0, True)
    add("unknown-fields", dict(payload, extra={"anything": [1, 2, "ignored"]}), 2, True)
    add("long-notes", dict(payload, notes="x" * 2100), 2, True)
    import uuid
    input_dir = pc_out + "\\contract-inputs-" + uuid.uuid4().hex
    setup = ". " + windows.ps_literal(receipt["stagingPath"] + "/tools/validation/Update/Harness.Common.ps1") + ";Open-HarnessRun " + " ".join(windows.ps_literal(receipt[k]) for k in ("runRoot", "frameId", "manifestSha256")) + " " + windows.ps_literal(receipt["frameId"]) + ";Ensure-HarnessOutputDirectory " + windows.ps_literal(pc_out) + ";New-HarnessDirectory " + windows.ps_literal(input_dir) + " 'contract-inputs'|Out-Null"
    remote(setup, "contracts-directory")
    results = []
    for name, path, expected in cases:
        remote_manifest = input_dir + "\\" + path.name
        copy_to(path, remote_manifest)
        fields = {"Source": receipt["stagingPath"], "OutRoot": pc_out, "Action": "contract-probe", "Probe": builds + r"\probe\UpdateProbe.exe", "Manifest": remote_manifest, "FeedUrl": FEED, "CurrentVersion": VERSION_A}
        if name in ("valid", "unknown-fields", "long-notes"):
            fields["InstallerPath"] = builds + "\\B\\" + installer.name
        invocation = interactive(receipt, "tools/validation/Update/Invoke-UpdateFixture.ps1", fields, "contract_" + name.replace("-", "_"))
        result = windows.read_result(HOST, MACHINE, receipt, "contract.json", invocation["nonce"])
        result_path = directory / (name + "-result.json")
        result_path.write_text(json.dumps(dict(nonce=invocation["nonce"], data=result), indent=2))
        if result["result"]["Kind"] != expected:
            raise RuntimeError("Contract outcome differs: " + name)
        if name == "long-notes" and len(result["result"]["Release"]["Notes"]) != 2000:
            raise RuntimeError("Release notes were not truncated")
        if result.get("file") and not result["file"]["Verified"]:
            raise RuntimeError("Correct installer was refused: " + name)
        results.append({"case": name, "nonce": invocation["nonce"], "frameId": receipt["frameId"], "expected": expected, "observed": result["result"]["Kind"], "reason": result["result"]["Reason"]})
    (directory / "results.json").write_text(json.dumps(results, indent=2))
    print(str(len(results)) + " signed-feed contract cases completed", flush=True)


def main():
    global OUT, HOST, MACHINE, FEED, KEY, VERSION_A, VERSION_B, FRAME_RECEIPT
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", default="all", choices=["all", "build", "seed", "manual-install", "feed-down", "slow-feed", "malformed-feed", "bad-signature", "wrong-product", "wrong-channel", "same-version", "older-version", "tampered", "tampered-size", "manual-download", "ready", "scheduled-download", "blocked", "cancel", "install", "failure", "copy-failure", "cleanup", "contracts", "transport-error", "manual-timeout", "settings-readonly", "timer-read-failure"])
    parser.add_argument("--host", default=os.environ.get("ROO_TEST_SSH_HOST"))
    parser.add_argument("--expected-machine", default=os.environ.get("ROO_TEST_COMPUTER"))
    parser.add_argument("--feed-url", default=os.environ.get("ROO_TEST_UPDATE_FEED"))
    parser.add_argument("--signing-key", type=Path, default=os.environ.get("ROO_UPDATE_SIGNING_KEY"))
    parser.add_argument("--out-dir", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--fixture-exe")
    parser.add_argument("--scenario-script", default="tools/validation/Update/Invoke-UpdateScenario.ps1")
    parser.add_argument("--manual-retry", action="store_true")
    parser.add_argument("--transport-fault", choices=["http-error", "disconnect"], default="disconnect")
    parser.add_argument("--build-root")
    parser.add_argument("--evidence-root")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-contracts", action="store_true")
    parser.add_argument("--from-scenario", help="Resume the all-scenarios journey at a named scenario using its retained baseline")
    args = parser.parse_args()
    if args.scenario == "contracts" and args.skip_contracts:
        parser.error("--scenario contracts cannot be combined with --skip-contracts")
    missing = [name for name in ("host", "expected_machine", "feed_url", "signing_key") if not getattr(args, name)]
    if missing:
        parser.error("Required test configuration is missing: " + ", ".join("--" + name.replace("_", "-") for name in missing) + ". Supply arguments or the corresponding ROO_TEST_* / ROO_UPDATE_SIGNING_KEY environment variables.")
    HOST, MACHINE, FEED, KEY = args.host, args.expected_machine, args.feed_url, args.signing_key
    parsed_feed = urlsplit(FEED)
    if parsed_feed.scheme != "https" or not parsed_feed.hostname or parsed_feed.port != 8460 or not parsed_feed.path.endswith("/beta.json") or parsed_feed.query or parsed_feed.fragment or ".." in parsed_feed.path.split("/"):
        parser.error("--feed-url must be an HTTPS test feed on port 8460 ending in /beta.json, without a query, fragment or traversal")
    windows.assert_external_signing_key(KEY)
    if not KEY.is_file():
        parser.error("--signing-key does not exist on this Linux machine")
    project = ROOT / "docs/internal/frontend/RooIndustries.OptimizationSuite.App/RooIndustries.OptimizationSuite.App.csproj"
    VERSION_A = ET.parse(project).find('.//Version').text.strip()
    version = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?', VERSION_A)
    if not version:
        parser.error("The source App Version must be a SemVer release version.")
    major, minor, patch = (int(version[i]) for i in (1, 2, 3))
    VERSION_B = f'{major}.{minor}.{patch + 1}' + (version[4] or '')
    older_version = (f'{major}.{minor}.{patch - 1}' if patch else f'{major}.{minor - 1}.0' if minor else f'{major - 1}.0.0') + (version[4] or '') if major or minor or patch else '0.0.0-0'

    if args.out_dir:
        OUT = args.out_dir.resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    receipt_path = args.receipt or OUT / "receipt.json"
    if args.scenario in ("all", "build") and args.receipt is None and not args.skip_build:
        receipt = windows.upload(HOST, MACHINE, "roo-industries-roo20-ota", True, r"C:\RooBuild")
        receipt_path.write_text(json.dumps(receipt, indent=2))
    else:
        receipt = json.loads(receipt_path.read_text())
    FRAME_RECEIPT = receipt
    windows.verify_local_source(HOST, MACHINE, receipt)
    frame = receipt["runRoot"]
    source = receipt["stagingPath"]
    pc_out = args.evidence_root or frame + r"\ota"
    builds = args.build_root or pc_out + r"\builds"
    if args.scenario in ("all", "build") and not args.skip_build:
        built = interactive(receipt, "tools/validation/Update/Build-UpdatePair.ps1", {"Source": source, "OutputRoot": builds, "FeedUrl": FEED, "VersionA": VERSION_A, "VersionB": VERSION_B}, "BuildPair", 40)
        for build, version in (("A", VERSION_A), ("B", VERSION_B)):
            name = "RooIndustries-OptimizationSuite-" + version + "-setup.exe"
            copy_from(builds + "\\" + build + "\\" + name, OUT / "builds" / build / name)
            copy_from(builds + "\\" + build + "\\" + name + ".sha256", OUT / "builds" / build / (name + ".sha256"))
        (OUT / "build-times.json").write_text(json.dumps(windows.read_result(HOST, MACHINE, receipt, "build-times.json", built["nonce"]), indent=2))
        if args.scenario == "build":
            return
    a = OUT / ("builds/A/RooIndustries-OptimizationSuite-" + VERSION_A + "-setup.exe")
    b = OUT / ("builds/B/RooIndustries-OptimizationSuite-" + VERSION_B + "-setup.exe")
    http_root = OUT / "http-root"
    feed_file = http_root / parsed_feed.path.lstrip("/")
    feed_file.parent.mkdir(parents=True, exist_ok=True)
    installer_file = feed_file.parent / "b/baseline" / b.name
    installer_file.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(b, installer_file)
    url = urljoin(FEED, "b/baseline/" + b.name)
    valid = OUT / "newer.json"
    expected_hash = json.loads(base64.b64decode(json.loads(valid.read_text())["payload"]))["installer"]["sha256"] if valid.exists() else None
    import hashlib
    with b.open("rb") as input_file:
        actual_hash = hashlib.file_digest(input_file, "sha256").hexdigest()
    if not valid.exists() or actual_hash != expected_hash:
        signed(b, VERSION_B, url, valid)
        envelope = json.loads(valid.read_text())
        signature = bytearray(base64.b64decode(envelope["signature"]))
        signature[-1] ^= 1
        envelope["signature"] = base64.b64encode(signature).decode()
        (OUT / "bad-signature.json").write_text(json.dumps(envelope))
    envelope = json.loads(valid.read_text())
    payload = json.loads(base64.b64decode(envelope["payload"]))
    private = serialization.load_pem_private_key(KEY.read_bytes(), password=None)
    for name, field, value in [("same", "version", VERSION_A), ("older", "version", older_version), ("wrong-product", "product", "another.product"), ("wrong-channel", "channel", "stable")]:
        data = json.dumps(dict(payload, **{field: value}), ensure_ascii=False, separators=(",", ":")).encode()
        variant = dict(envelope, payload=base64.b64encode(data).decode(), signature=base64.b64encode(private.sign(data, ec.ECDSA(hashes.SHA256()))).decode())
        (OUT / (name + ".json")).write_text(json.dumps(variant))
    if args.scenario in ("all", "contracts") and not args.skip_contracts:
        contracts(receipt, builds, pc_out, b, valid)
        if args.scenario == "contracts":
            return
    ledger_path = OUT / "scenario-results.json"
    ledger = json.loads(ledger_path.read_text()) if args.from_scenario else {"frameId": receipt["frameId"], "manifestSha256": receipt["manifestSha256"], "checks": []}
    if ledger["frameId"] != receipt["frameId"] or ledger["manifestSha256"] != receipt["manifestSha256"] or any(row["status"] != "pass" or row.get("frameId") != receipt["frameId"] for row in ledger["checks"]):
        raise RuntimeError("Resume requires earlier pass rows on this exact frame")
    server = None
    log = None
    serving = False
    server_entry = None
    server_handle = None
    server_birth = None
    serve_entry = None
    client_nonce = uuid.uuid4().hex
    def local_creation(pid):
        stat = Path('/proc/' + str(pid) + '/stat').read_text()
        return Path('/proc/sys/kernel/random/boot_id').read_text().strip() + ':' + stat[stat.rfind(')') + 2:].split()[19]
    def ledger_scope():
        return ". " + windows.ps_literal(receipt["stagingPath"] + "/tools/validation/Update/Harness.Common.ps1") + ";Open-HarnessRun " + " ".join(windows.ps_literal(receipt[k]) for k in ("runRoot", "frameId", "manifestSha256")) + " " + windows.ps_literal(client_nonce) + ";"
    def record_local(kind, identity, purpose):
        value = base64.b64encode(json.dumps(identity).encode()).decode()
        return remote(ledger_scope() + "$id=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + value + "'))|ConvertFrom-Json;($e=Add-HarnessEntry " + windows.ps_literal(kind) + " $id " + windows.ps_literal(purpose) + " 'run' @{platform='linux';host=" + windows.ps_literal(socket.gethostname()) + "}).id", "local-ledger-record").strip()
    def retire_local(entry):
        remote(ledger_scope() + "Set-HarnessEntryState " + windows.ps_literal(entry) + " 'removed'", "local-ledger-cleanup")
    def start_server(fault=None):
        nonlocal server, log, server_entry, server_handle, server_birth
        if server is None:
            log = (OUT / "http-server.log").open("a")
            args = [sys.executable, "-I", ROOT / "tools/validation/Update/serve_fixture.py", "--directory", str(http_root), "--feed-path", parsed_feed.path, "--fault", fault] if fault else [sys.executable, "-m", "http.server", "13684", "--bind", "127.0.0.1", "--directory", str(http_root)]
            server = subprocess.Popen(args, stdout=log, stderr=log)
            server_handle = os.pidfd_open(server.pid)
            server_birth = local_creation(server.pid)
            server_entry = record_local('process', {'pid': server.pid, 'creationTimeNative': server_birth, 'imagePath': str(Path(sys.executable).resolve())}, 'http-server')
            for attempt in range(40):
                if server.poll() is not None:
                    raise RuntimeError("Owned HTTP server exited")
                try:
                    with socket.create_connection(("127.0.0.1", 13684), timeout=1):
                        break
                except OSError:
                    time.sleep(0.1)
            (OUT / "owned-server.json").write_text(json.dumps({"pid": server.pid, "host": socket.gethostname(), "port": 13684, "httpsPort": 8460}))
    def stop_server():
        nonlocal server, log, server_handle, server_entry
        if server:
            if server.poll() is None:
                if local_creation(server.pid) != server_birth:
                    raise RuntimeError('Owned HTTP-server identity changed; retained.')
                signal.pidfd_send_signal(server_handle, signal.SIGTERM)
            server.wait(timeout=10)
            os.close(server_handle)
            retire_local(server_entry)
            server_handle = server_entry = None
            server = None
        if log:
            log.close()
            log = None
    last_invocation = None
    def scenario(name, installer=None, evidence_name=None):
        nonlocal last_invocation
        fields = {"Source": source, "OutRoot": pc_out, "Scenario": name, "ExpectedVersion": VERSION_A, "NextVersion": VERSION_B}
        if args.manual_retry:
            fields["ManualRetry"] = True
        if installer:
            fields["InstallerPath"] = installer
        if evidence_name:
            fields["EvidenceName"] = evidence_name
        if name == "timer-read-failure":
            if not args.fixture_exe:
                raise RuntimeError("timer-read-failure requires --fixture-exe from the hook-only app copy")
            fields["FixtureExe"] = args.fixture_exe
        last_invocation = interactive(receipt, args.scenario_script, fields, name.replace("-", "_"), 24 if name == "manual-timeout" else 12)
        return last_invocation
    def fixture(action):
        interactive(receipt, "tools/validation/Update/Invoke-UpdateFixture.ps1", {"Source": source, "OutRoot": pc_out, "Action": action, "Version": VERSION_B, "CurrentVersion": VERSION_A}, action.replace("-", "_"), 8)
    try:
        status = command(["tailscale", "serve", "status", "--json"], OUT / "tailscale-before.json")
        if "8460" in status:
            raise RuntimeError("Tailnet HTTPS port 8460 already belongs to another service")
        shutil.copyfile(OUT / "same.json", feed_file)
        start_server()
        command(["sudo", "-n", "tailscale", "serve", "--bg", "--https=8460", "http://127.0.0.1:13684"], OUT / "tailscale-start.log")
        serving = True
        serve_entry = record_local('tailnet', {'httpsPort': 8460, 'proxy': 'http://127.0.0.1:13684', 'nonce': client_nonce}, 'https-serve')
        remote("$r=Invoke-WebRequest -UseBasicParsing " + windows.ps_literal(FEED) + ";@{status=$r.StatusCode;bytes=$r.RawContentLength}|ConvertTo-Json", "feed-reachability")
        sequence = ["seed", "manual-install", "feed-down", "slow-feed", "malformed-feed", "bad-signature", "wrong-product", "wrong-channel", "same-version", "older-version", "tampered", "tampered-size", "manual-download", "ready", "scheduled-download", "blocked", "cancel", "install", "failure", "copy-failure", "cleanup"] if args.scenario == "all" else [args.scenario]
        if args.from_scenario:
            prior = sequence[:sequence.index(args.from_scenario)]
            if any(not any(row['check'] == name and row['status'] == 'pass' for row in ledger['checks']) for name in prior):
                raise RuntimeError('Cannot resume: required earlier scenarios did not pass on this receipt')
            sequence = sequence[sequence.index(args.from_scenario):]
        ledger["required"] = sequence if not args.from_scenario else ledger["required"]
        ledger["status"] = "running"
        ledger_path.write_text(json.dumps(ledger, indent=2))
        for name in sequence:
            ledger["current"] = name
            if name in ("seed", "manual-install", "feed-down", "slow-feed", "malformed-feed", "bad-signature", "wrong-product", "wrong-channel", "same-version", "older-version", "tampered", "tampered-size", "manual-download", "transport-error", "manual-timeout"):
                fixture("reset-download")
            if name == "feed-down":
                stop_server()
            elif name in ("slow-feed", "transport-error", "manual-timeout"):
                stop_server()
                start_server(fault={"slow-feed": "slow-feed", "transport-error": args.transport_fault, "manual-timeout": "stall-installer"}[name])
            else:
                if name == "malformed-feed":
                    stop_server()
                start_server()
            if name in ("seed", "manual-install", "same-version", "cleanup", "settings-readonly"):
                shutil.copyfile(OUT / "same.json", feed_file)
            elif name == "older-version":
                shutil.copyfile(OUT / "older.json", feed_file)
            elif name in ("bad-signature", "wrong-product", "wrong-channel"):
                shutil.copyfile(OUT / (name + ".json"), feed_file)
            elif name == "malformed-feed":
                feed_file.write_bytes(b"{")
            elif name in ("feed-down", "slow-feed"):
                shutil.copyfile(OUT / "same.json", feed_file)
            else:
                shutil.copyfile(valid, feed_file)
            if name == "tampered":
                with installer_file.open("r+b") as target:
                    target.seek(-1, os.SEEK_END)
                    byte = target.read(1)
                    target.seek(-1, os.SEEK_END)
                    target.write(bytes([byte[0] ^ 1]))
            elif name == "tampered-size":
                with installer_file.open("ab") as target:
                    target.write(b"x")
            if name == "manual-install":
                scenario(name, builds + "\\A\\" + a.name)
            elif name == "blocked":
                fixture("start-game")
                try:
                    scenario(name)
                finally:
                    fixture("stop-game")
            elif name in ("ready", "scheduled-download"):
                fixture("reset-download")
                scenario(name)
            elif name == "failure":
                shutil.copyfile(OUT / "same.json", feed_file)
                scenario("manual-install", builds + "\\A\\" + a.name, "reset-A")
                shutil.copyfile(valid, feed_file)
                scenario("ready")
                fixture("block-setup")
                try:
                    scenario(name)
                finally:
                    fixture("unblock-setup")
            elif name == "copy-failure":
                shutil.copyfile(OUT / "same.json", feed_file)
                scenario("manual-install", builds + "\\A\\" + a.name, "reset-A-before-copy-failure")
                fixture("reset-download")
                fixture_installer = OUT / "builds/copy-failure" / b.name
                interactive(receipt, "tools/validation/Update/Build-CopyFailureFixture.ps1", {"Source": source, "Stage": builds + "\\B\\work-" + VERSION_B + r"\stage", "OutRoot": builds + r"\copy-failure"}, "BuildCopyFailure", 8)
                copy_from(builds + "\\copy-failure\\" + b.name, fixture_installer)
                shutil.copyfile(fixture_installer, installer_file)
                copy_manifest = OUT / "copy-failure.json"
                signed(fixture_installer, VERSION_B, url, copy_manifest)
                shutil.copyfile(copy_manifest, feed_file)
                scenario("ready", evidence_name="copy-failure-ready")
                scenario(name)
                shutil.copyfile(OUT / "same.json", feed_file)
                scenario("manual-install", builds + "\\A\\" + a.name, "reset-A-after-copy-failure")
            elif name == "contracts":
                raise RuntimeError("Contracts must run the contract probe entry point")
            else:
                scenario(name)
            ledger["checks"].append({"check": name, "status": "pass", "frameId": receipt["frameId"], "nonce": last_invocation["nonce"]})
            ledger_path.write_text(json.dumps(ledger, indent=2))
            if name in ("tampered", "tampered-size"):
                shutil.copyfile(b, installer_file)
        fixture("read-security")
        ledger["status"] = "pass"
    except Exception:
        ledger["checks"].append({"check": ledger.get("current", "setup"), "status": "fail", "frameId": receipt["frameId"]})
        ledger["status"] = "fail"
        raise
    finally:
        try:
            try:
                if serving:
                    current = json.loads(command(["tailscale", "serve", "status", "--json"]))
                    targets = [handler.get('Proxy') for key, web in current.get('Web', {}).items() if key.endswith(':8460') for handler in web.get('Handlers', {}).values()]
                    if targets != ['http://127.0.0.1:13684']:
                        raise RuntimeError('Owned tailnet route changed; retained.')
                    command(["sudo", "-n", "tailscale", "serve", "--https=8460", "off"], OUT / "tailscale-stop.log")
                    retire_local(serve_entry)
            finally:
                stop_server()
            after = command(["tailscale", "serve", "status", "--json"], OUT / "tailscale-after.json")
            if json.loads(after) != json.loads(status):
                raise RuntimeError('Tailnet configuration differs from its as-found JSON.')
            evidence = pc_out + "\\evidence-" + uuid.uuid4().hex + ".zip"
            scope = ". " + windows.ps_literal(receipt["stagingPath"] + "/tools/validation/Update/Harness.Common.ps1") + ";Open-HarnessRun " + " ".join(windows.ps_literal(receipt[k]) for k in ("runRoot", "frameId", "manifestSha256")) + " " + windows.ps_literal(receipt["frameId"]) + ";"
            remote(scope + "$items=@(Get-ChildItem -LiteralPath " + windows.ps_literal(pc_out) + " | Where-Object {$_.Name -notin @('builds','contracts','game-fixture','rule-inspect','obj','bin','timer-fixtures')});if(Test-Path " + windows.ps_literal(evidence) + "){throw 'Evidence archive already exists; retained.'};Compress-Archive -LiteralPath $items.FullName -DestinationPath " + windows.ps_literal(evidence) + ";Register-HarnessFile " + windows.ps_literal(evidence) + " 'evidence-archive'|Out-Null", "collect-evidence")
            copy_from(evidence, OUT / "pc-evidence.zip")
            import zipfile
            with zipfile.ZipFile(OUT / "pc-evidence.zip") as archive:
                for entry in archive.infolist():
                    relative = Path(entry.filename.replace("\\", "/"))
                    if relative.is_absolute() or ".." in relative.parts:
                        raise RuntimeError("Unexpected evidence archive path")
                    target = OUT / "pc-artifacts/ota" / relative
                    if not entry.is_dir() and not entry.filename.endswith(("/", "\\")):
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(archive.read(entry))
        except Exception:
            ledger["status"] = "fail"
            ledger["checks"].append({"check": "cleanup", "status": "fail", "frameId": receipt["frameId"]})
            raise
        finally:
            ledger_path.write_text(json.dumps(ledger, indent=2))


if __name__ == "__main__":
    main()
