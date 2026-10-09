import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT = Path(__file__).resolve().parents[2]
KEYS = json.loads((ROOT / "tools/release/update-keys.json").read_text())
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\Z")


def check_version(value):
    match = VERSION.fullmatch(value) if isinstance(value, str) else None
    if not match or (match[4] and any(p.isascii() and p.isdecimal() and len(p) > 1 and p[0] == "0" for p in match[4].split("."))):
        raise ValueError("Invalid SemVer release version")


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON property: " + key)
        result[key] = value
    return result


def read_json(data):
    return json.loads(data, object_pairs_hook=unique, parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Invalid JSON number")))


def file_identity(path):
    count = 0
    sha = hashlib.sha256()
    with Path(path).open("rb") as source:
        while block := source.read(1024 * 1024):
            count += len(block)
            sha.update(block)
    return count, sha.hexdigest()


def trusted_key(key_id):
    if key_id not in KEYS:
        raise ValueError("Unknown signing key")
    key = serialization.load_der_public_key(base64.b64decode(KEYS[key_id], validate=True))
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise ValueError("Trusted key is not ECDSA P-256")
    project = (ROOT / "backend/native/Optimizer.Core/Optimizer.Core.csproj").read_text()
    if 'EmbeddedResource Include="../../../tools/release/update-keys.json" LogicalName="Optimizer.Core.UpdateKeys.json"' not in project:
        raise ValueError("Optimizer.Core no longer embeds the release tool's trusted key list")
    return key


def verify_manifest(data, installer=None, feed_url=None):
    if len(data) > 65536:
        raise ValueError("Manifest exceeds 64 KiB")
    envelope = read_json(data)
    if type(envelope.get("schemaVersion")) is not int or envelope["schemaVersion"] != 1:
        raise ValueError("Unsupported envelope schema")
    payload_bytes = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    trusted_key(envelope["keyId"]).verify(signature, payload_bytes, ec.ECDSA(hashes.SHA256()))
    payload = read_json(payload_bytes)
    if type(payload.get("schemaVersion")) is not int or payload["schemaVersion"] != 1:
        raise ValueError("Unsupported payload schema")
    if payload.get("product") != "RooIndustries.OptimizationSuite" or payload.get("channel") != "beta":
        raise ValueError("Wrong product or channel")
    check_version(payload.get("version"))
    published = payload["publishedAtUtc"]
    if not published.endswith("Z") or datetime.fromisoformat(published).utcoffset().total_seconds() != 0:
        raise ValueError("Invalid UTC publication time")
    item = payload["installer"]
    url = urlparse(item["url"])
    if url.scheme != "https" or not url.hostname:
        raise ValueError("Installer URL must use HTTPS")
    if feed_url and url.hostname.lower() != urlparse(feed_url).hostname.lower():
        raise ValueError("Installer and feed hosts differ")
    if type(item["size"]) is not int or not 1048576 <= item["size"] <= 1073741824:
        raise ValueError("Installer must be between 1 MiB and 1 GiB")
    if not re.fullmatch("[0-9a-fA-F]{64}", item["sha256"]):
        raise ValueError("Invalid installer SHA-256")
    if "notes" in payload and not isinstance(payload["notes"], str):
        raise ValueError("Release notes must be plain text")
    if installer and file_identity(installer) != (item["size"], item["sha256"].lower()):
        raise ValueError("Installer size or SHA-256 differs from the signed manifest")
    return payload


def manifest(args):
    check_version(args.version)
    size, sha = file_identity(args.installer)
    key_bytes = Path(args.key).read_bytes()
    private = serialization.load_pem_private_key(key_bytes, password=None)
    del key_bytes
    if not isinstance(private, ec.EllipticCurvePrivateKey) or not isinstance(private.curve, ec.SECP256R1):
        raise ValueError("Signing key must be ECDSA P-256")
    spki = base64.b64encode(private.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).decode()
    key_id = next((name for name, value in KEYS.items() if value == spki), None)
    if key_id is None:
        raise ValueError("Signing key is not in the compiled trusted key list")
    notes = Path(args.notes_file).read_text(encoding="utf-8").encode("utf-16-le")[:4000].decode("utf-16-le", errors="ignore")
    payload = {"schemaVersion": 1, "product": "RooIndustries.OptimizationSuite", "channel": "beta", "version": args.version,
               "publishedAtUtc": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
               "installer": {"url": args.url, "size": size, "sha256": sha}, "notes": notes}
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    signed = {"schemaVersion": 1, "keyId": key_id, "payload": base64.b64encode(data).decode(),
              "signature": base64.b64encode(private.sign(data, ec.ECDSA(hashes.SHA256()))).decode()}
    envelope = (json.dumps(signed, separators=(",", ":")) + "\n").encode("utf-8")
    verify_manifest(envelope, args.installer)
    Path(args.out).write_bytes(envelope)
    print(json.dumps({"manifest": str(args.out), "version": args.version, "size": size, "sha256": sha, "keyId": key_id}))


def fetch(url, limit):
    with urlopen(Request(url, headers={"Cache-Control": "no-cache"}), timeout=20) as response:
        if response.status != 200 or urlparse(response.url).scheme != "https":
            raise ValueError("Published URL did not return HTTPS HTTP 200")
        data = response.read(limit + 1)
        if len(data) > limit:
            raise ValueError("Published response exceeds its bound")
        return data


def publish(args):
    feed = (ROOT / "tools/release/update-feed.txt").read_text().strip()
    payload = verify_manifest(Path(args.manifest).read_bytes(), args.installer, feed)
    if not re.fullmatch(r"b/[A-Za-z0-9_-]+/RooIndustries-OptimizationSuite-[0-9A-Za-z.+-]+-setup\.exe", args.installer_path):
        raise ValueError("Use an immutable b/<random>/<installer> path")
    if not re.fullmatch(r"u/[A-Za-z0-9_-]+/beta\.json", args.feed_path) or urlparse(feed).path != "/" + args.feed_path:
        raise ValueError("Feed path differs from the committed feed")
    if urlparse(payload["installer"]["url"]).path != "/" + args.installer_path:
        raise ValueError("Installer path differs from the signed URL")
    commands = [
        ["vercel", "blob", "put", str(args.installer), "--access", "public", "--pathname", args.installer_path, "--add-random-suffix", "false", "--allow-overwrite", "false", "--content-type", "application/octet-stream"],
        ["vercel", "blob", "put", str(args.manifest), "--access", "public", "--pathname", args.feed_path, "--add-random-suffix", "false", "--allow-overwrite", "true", "--cache-control-max-age", "60", "--content-type", "application/json"],
    ]
    for command in commands:
        print(shlex.join(command))
    if not args.yes_publish:
        print("Dry run: nothing uploaded. Publishing requires --yes-publish and user authorization.")
        return
    if not os.environ.get("BLOB_READ_WRITE_TOKEN"):
        raise ValueError("BLOB_READ_WRITE_TOKEN is missing from the environment")
    for index, command in enumerate(commands):
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if result.returncode:
            raise ValueError("Blob upload " + str(index + 1) + " failed with exit code " + str(result.returncode))
    remote = fetch(feed + "?t=" + str(int(datetime.now(timezone.utc).timestamp())), 65536)
    published = verify_manifest(remote, feed_url=feed)
    if remote != Path(args.manifest).read_bytes():
        raise ValueError("Published feed has not propagated to the signed bytes yet")
    item = published["installer"]
    sha = hashlib.sha256()
    total = 0
    with urlopen(Request(item["url"], headers={"Cache-Control": "no-cache"}), timeout=20) as response:
        if response.status != 200 or urlparse(response.url).scheme != "https":
            raise ValueError("Published installer did not return HTTPS HTTP 200")
        while total <= item["size"]:
            block = response.read(min(1048576, item["size"] + 1 - total))
            if not block:
                break
            total += len(block)
            sha.update(block)
    if (total, sha.hexdigest()) != (item["size"], item["sha256"].lower()):
        raise ValueError("Published installer differs from the signed manifest")
    print("Published manifest and installer verified over HTTPS.")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("manifest")
    for name in ("installer", "version", "url", "notes-file", "key", "out"):
        make.add_argument("--" + name, required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--installer")
    verify.add_argument("--feed-url")
    send = commands.add_parser("publish")
    for name in ("installer", "manifest", "installer-path", "feed-path"):
        send.add_argument("--" + name, required=True)
    send.add_argument("--yes-publish", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "manifest":
            manifest(args)
        elif args.command == "verify":
            payload = verify_manifest(Path(args.manifest).read_bytes(), args.installer, args.feed_url)
            print(json.dumps({"verified": True, "version": payload["version"], "installer": payload["installer"]}))
        else:
            publish(args)
    except (ValueError, KeyError, TypeError, AttributeError, OSError, InvalidSignature) as error:
        print("Update release refused: " + ("Invalid signature" if isinstance(error, InvalidSignature) else str(error)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
