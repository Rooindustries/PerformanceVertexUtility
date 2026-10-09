import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
from urllib.request import urlopen
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "artifacts/roo-20/ota"
HOST = "optimizer-9070"
MACHINE = "SERVI-WINDOWS-D"
FEED = "https://roo-devbox.tail9fe6d9.ts.net:8460/ota-e2e/beta.json"
KEY = Path("/home/serviroo/.config/roo-industries/update-signing/roo-update-signing-p256.pem")
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
    print(name + " completed", flush=True)


def copy_from(remote_path, destination):
    Path(destination).parent.mkdir(parents=True, exist_ok=True)
    command(["scp", HOST + ":" + remote_path.replace("\\", "/"), destination])


def copy_to(local_path, remote_path):
    command(["scp", local_path, HOST + ":" + remote_path.replace("\\", "/")])


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
    for name, field, value in [("http-installer", "url", "http://roo-devbox.tail9fe6d9.ts.net:8460/setup.exe"),
                               ("different-host", "url", "https://example.com/setup.exe"), ("undersized", "size", 1048575),
                               ("oversized-installer", "size", 1073741825), ("bad-hash", "sha256", "g" * 64),
                               ("short-hash", "sha256", "a" * 63)]:
        add(name, dict(payload, installer=dict(payload["installer"], **{field: value})), 0, True)
    add("unknown-fields", dict(payload, extra={"anything": [1, 2, "ignored"]}), 2, True)
    add("long-notes", dict(payload, notes="x" * 2100), 2, True)
    remote("[IO.Directory]::CreateDirectory(" + windows.ps_literal(pc_out + r"\contracts") + ")|Out-Null", "contracts-directory")
    results = []
    for name, path, expected in cases:
        remote_manifest = pc_out + "\\contracts\\" + path.name
        remote_result = pc_out + "\\contracts\\" + name + "-result.json"
        copy_to(path, remote_manifest)
        call = "& " + windows.ps_literal(builds + r"\probe\UpdateProbe.exe") + " " + " ".join(windows.ps_literal(value) for value in [remote_manifest, FEED, "0.11.0-beta", remote_result])
        if name in ("valid", "unknown-fields", "long-notes"):
            call += " " + windows.ps_literal(builds + "\\B\\" + installer.name)
        remote(call + ";if($LASTEXITCODE -ne 0){throw 'Contract probe failed'}", "contract-" + name)
        result_path = directory / (name + "-result.json")
        copy_from(remote_result, result_path)
        result = json.loads(result_path.read_text())
        if result["result"]["Kind"] != expected:
            raise RuntimeError("Contract outcome differs: " + name)
        if name == "long-notes" and len(result["result"]["Release"]["Notes"]) != 2000:
            raise RuntimeError("Release notes were not truncated")
        if result.get("file") and not result["file"]["Verified"]:
            raise RuntimeError("Correct installer was refused: " + name)
        results.append({"case": name, "expected": expected, "observed": result["result"]["Kind"], "reason": result["result"]["Reason"]})
    (directory / "results.json").write_text(json.dumps(results, indent=2))
    print(str(len(results)) + " signed-feed contract cases completed", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", default="all", choices=["all", "build", "seed", "manual-install", "feed-down", "slow-feed", "malformed-feed", "bad-signature", "wrong-product", "wrong-channel", "same-version", "older-version", "tampered", "tampered-size", "manual-download", "ready", "scheduled-download", "blocked", "cancel", "install", "failure", "cleanup", "contracts"])
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--build-root")
    parser.add_argument("--evidence-root")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-contracts", action="store_true")
    parser.add_argument("--from-scenario", help="Resume the all-scenarios journey at a named scenario using its retained baseline")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    receipt_path = args.receipt or OUT / "receipt.json"
    if args.scenario in ("all", "build") and args.receipt is None and not args.skip_build:
        receipt = windows.upload(HOST, MACHINE, "roo-industries-roo20-ota", True, r"C:\RooBuild")
        receipt_path.write_text(json.dumps(receipt, indent=2))
    else:
        receipt = json.loads(receipt_path.read_text())
    frame = receipt["runRoot"]
    source = receipt["stagingPath"]
    pc_out = args.evidence_root or frame + r"\ota"
    builds = args.build_root or pc_out + r"\builds"
    if args.scenario in ("all", "build") and not args.skip_build:
        interactive(receipt, "tools/validation/Update/Build-UpdatePair.ps1", {"Source": source, "OutputRoot": builds, "FeedUrl": FEED}, "BuildPair", 40)
        for build, version in (("A", "0.11.0-beta"), ("B", "0.11.1-beta")):
            name = "RooIndustries-OptimizationSuite-" + version + "-setup.exe"
            copy_from(builds + "\\" + build + "\\" + name, OUT / "builds" / build / name)
            copy_from(builds + "\\" + build + "\\" + name + ".sha256", OUT / "builds" / build / (name + ".sha256"))
        copy_from(builds + r"\build-times.json", OUT / "build-times.json")
        if args.scenario == "build":
            return
    a = OUT / "builds/A/RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe"
    b = OUT / "builds/B/RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe"
    http_root = OUT / "http-root"
    feed_file = http_root / "ota-e2e/beta.json"
    feed_file.parent.mkdir(parents=True, exist_ok=True)
    installer_file = http_root / "ota-e2e/b/baseline" / b.name
    installer_file.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(b, installer_file)
    url = "https://roo-devbox.tail9fe6d9.ts.net:8460/ota-e2e/b/baseline/" + b.name
    valid = OUT / "newer.json"
    expected_hash = json.loads(base64.b64decode(json.loads(valid.read_text())["payload"]))["installer"]["sha256"] if valid.exists() else None
    import hashlib
    with b.open("rb") as input_file:
        actual_hash = hashlib.file_digest(input_file, "sha256").hexdigest()
    if not valid.exists() or actual_hash != expected_hash:
        signed(b, "0.11.1-beta", url, valid)
        envelope = json.loads(valid.read_text())
        signature = bytearray(base64.b64decode(envelope["signature"]))
        signature[-1] ^= 1
        envelope["signature"] = base64.b64encode(signature).decode()
        (OUT / "bad-signature.json").write_text(json.dumps(envelope))
    envelope = json.loads(valid.read_text())
    payload = json.loads(base64.b64decode(envelope["payload"]))
    private = serialization.load_pem_private_key(KEY.read_bytes(), password=None)
    for name, field, value in [("same", "version", "0.11.0-beta"), ("older", "version", "0.10.0-beta"), ("wrong-product", "product", "another.product"), ("wrong-channel", "channel", "stable")]:
        data = json.dumps(dict(payload, **{field: value}), ensure_ascii=False, separators=(",", ":")).encode()
        variant = dict(envelope, payload=base64.b64encode(data).decode(), signature=base64.b64encode(private.sign(data, ec.ECDSA(hashes.SHA256()))).decode())
        (OUT / (name + ".json")).write_text(json.dumps(variant))
    if args.scenario in ("all", "contracts") and not args.skip_contracts:
        contracts(receipt, builds, pc_out, b, valid)
        if args.scenario == "contracts":
            return
    server = None
    log = None
    serving = False
    def start_server(slow=False):
        nonlocal server, log
        if server is None:
            log = (OUT / "http-server.log").open("a")
            args = [sys.executable, "-I", ROOT / "tools/validation/Update/serve_fixture.py", "--directory", str(http_root)] if slow else [sys.executable, "-m", "http.server", "13684", "--bind", "127.0.0.1", "--directory", str(http_root)]
            server = subprocess.Popen(args, stdout=log, stderr=log)
            for attempt in range(40):
                if server.poll() is not None:
                    raise RuntimeError("Owned HTTP server exited")
                try:
                    with socket.create_connection(("127.0.0.1", 13684), timeout=1):
                        break
                except OSError:
                    time.sleep(0.1)
            (OUT / "owned-server.json").write_text(json.dumps({"pid": server.pid, "host": "linux-dev-box", "port": 13684, "httpsPort": 8460}))
    def stop_server():
        nonlocal server, log
        if server:
            server.terminate()
            server.wait(timeout=10)
            server = None
        if log:
            log.close()
            log = None
    def scenario(name, installer=None, evidence_name=None):
        fields = {"Source": source, "OutRoot": pc_out, "Scenario": name}
        if installer:
            fields["InstallerPath"] = installer
        if evidence_name:
            fields["EvidenceName"] = evidence_name
        interactive(receipt, "tools/validation/Update/Invoke-UpdateScenario.ps1", fields, name.replace("-", "_"), 12)
    def fixture(action):
        interactive(receipt, "tools/validation/Update/Invoke-UpdateFixture.ps1", {"Source": source, "OutRoot": pc_out, "Action": action}, action.replace("-", "_"), 8)
    try:
        status = command(["tailscale", "serve", "status", "--json"], OUT / "tailscale-before.json")
        if "8460" in status:
            raise RuntimeError("Tailnet HTTPS port 8460 already belongs to another service")
        shutil.copyfile(OUT / "same.json", feed_file)
        start_server()
        command(["sudo", "-n", "tailscale", "serve", "--bg", "--https=8460", "http://127.0.0.1:13684"], OUT / "tailscale-start.log")
        serving = True
        remote("$r=Invoke-WebRequest -UseBasicParsing " + windows.ps_literal(FEED) + ";@{status=$r.StatusCode;bytes=$r.RawContentLength}|ConvertTo-Json", "feed-reachability")
        sequence = ["seed", "manual-install", "feed-down", "slow-feed", "malformed-feed", "bad-signature", "wrong-product", "wrong-channel", "same-version", "older-version", "tampered", "tampered-size", "manual-download", "ready", "scheduled-download", "blocked", "cancel", "install", "failure", "cleanup"] if args.scenario == "all" else [args.scenario]
        if args.from_scenario:
            sequence = sequence[sequence.index(args.from_scenario):]
        for name in sequence:
            if name == "feed-down":
                stop_server()
            elif name == "slow-feed":
                stop_server()
                start_server(slow=True)
            else:
                if name == "malformed-feed":
                    stop_server()
                start_server()
            if name in ("seed", "manual-install", "same-version", "cleanup"):
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
            elif name == "contracts":
                remote("'Use UpdateProbe with each retained signed contract manifest.'", "contracts")
            else:
                scenario(name)
            if name in ("tampered", "tampered-size"):
                shutil.copyfile(b, installer_file)
        fixture("read-security")
    finally:
        try:
            if serving:
                command(["sudo", "-n", "tailscale", "serve", "--https=8460", "off"], OUT / "tailscale-stop.log")
        finally:
            stop_server()
        command(["tailscale", "serve", "status", "--json"], OUT / "tailscale-after.json")
        evidence = pc_out + "-evidence.zip"
        remote("$items=@(Get-ChildItem -LiteralPath " + windows.ps_literal(pc_out) + " | Where-Object {$_.Name -notin @('builds','contracts','game-fixture','rule-inspect','obj','bin')});Compress-Archive -LiteralPath $items.FullName -DestinationPath " + windows.ps_literal(evidence) + " -Force", "collect-evidence")
        copy_from(evidence, OUT / "pc-evidence.zip")
        import zipfile
        with zipfile.ZipFile(OUT / "pc-evidence.zip") as archive:
            for entry in archive.infolist():
                relative = Path(entry.filename.replace("\\", "/"))
                if relative.is_absolute() or ".." in relative.parts:
                    raise RuntimeError("Unexpected evidence archive path")
                target = OUT / "pc-artifacts/ota" / relative
                if not entry.is_dir():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(archive.read(entry))


if __name__ == "__main__":
    main()
