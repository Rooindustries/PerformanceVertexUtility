import argparse
import base64
import hashlib
import json
import mmap
import os
from pathlib import Path
import re
import shlex
import subprocess
import struct
import sys
from datetime import datetime, timezone
from http.client import HTTPException
from urllib.error import HTTPError
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


def precedence(value):
    check_version(value)
    match = VERSION.fullmatch(value)
    parts = match[4].split(".") if match[4] else []
    return [(len(n), n) for n in match.groups()[:3]], not parts, [(0, len(p), p) if p.isdecimal() else (1, p) for p in parts]


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


def product_version(path):
    with Path(path).open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as image:
        def unpack(fmt, offset):
            if offset < 0 or offset + struct.calcsize(fmt) > len(image):
                raise ValueError("Truncated installer PE resource")
            return struct.unpack_from(fmt, image, offset)
        if image[:2] != b"MZ":
            raise ValueError("Installer is not a Windows executable")
        pe = unpack("<I", 60)[0]
        if image[pe:pe + 4] != b"PE\0\0":
            raise ValueError("Installer has no PE header")
        sections = unpack("<H", pe + 6)[0]
        optional_size = unpack("<H", pe + 20)[0]
        optional = pe + 24
        magic = unpack("<H", optional)[0]
        directory = {0x10b: 96, 0x20b: 112}.get(magic)
        if directory is None or optional_size < directory + 24 or sections > 96:
            raise ValueError("Installer has an unsupported PE header")
        if unpack("<I", optional + directory - 4)[0] < 3:
            raise ValueError("Installer has no version resources")
        resource_rva, resource_size = unpack("<II", optional + directory + 16)
        section_table = optional + optional_size
        def mapped(rva, size):
            for index in range(sections):
                offset = section_table + index * 40
                virtual, address, raw_size, raw = unpack("<IIII", offset + 8)
                if address <= rva and rva - address + size <= raw_size:
                    result = raw + rva - address
                    if result + size <= len(image):
                        return result
            raise ValueError("Installer version resource points outside the PE image")
        if not 16 <= resource_size <= 16 * 1024 * 1024:
            raise ValueError("Installer resource directory is missing or too large")
        resource = bytes(image[mapped(resource_rva, resource_size):mapped(resource_rva, resource_size) + resource_size])
        def resource_unpack(fmt, offset):
            if offset < 0 or offset + struct.calcsize(fmt) > len(resource):
                raise ValueError("Installer resource offset is out of bounds")
            return struct.unpack_from(fmt, resource, offset)
        visited = set()
        versions = []
        def blocks(data, start, limit, parents=()):
            if len(parents) > 4 or start + 6 > limit:
                raise ValueError("Malformed installer version block")
            length, value_length, kind = struct.unpack_from("<HHH", data, start)
            end = start + length
            if length < 8 or end > limit or kind not in (0, 1):
                raise ValueError("Malformed installer version block length")
            key_end = start + 6
            while key_end + 2 <= end and data[key_end:key_end + 2] != b"\0\0":
                key_end += 2
            if key_end + 2 > end:
                raise ValueError("Unterminated installer version key")
            key = data[start + 6:key_end].decode("utf-16-le")
            value_start = (key_end + 5) & ~3
            value_end = value_start + value_length * (2 if kind else 1)
            if value_end > end:
                raise ValueError("Installer version value exceeds its block")
            if not parents and key != "VS_VERSION_INFO":
                raise ValueError("Installer version resource has the wrong root")
            if len(parents) == 3 and parents[1] == "StringFileInfo" and key == "ProductVersion":
                if kind != 1 or not value_length:
                    raise ValueError("Installer ProductVersion is not text")
                text = data[value_start:value_end].decode("utf-16-le").rstrip("\0").rstrip(" ")
                if "\0" in text:
                    raise ValueError("Installer ProductVersion contains a null")
                versions.append(text)
            child = (value_end + 3) & ~3
            while child + 6 <= end:
                child = (blocks(data, child, end, parents + (key,)) + 3) & ~3
            return end
        def walk(offset, level):
            if level > 2 or offset in visited or len(visited) > 256:
                raise ValueError("Malformed installer resource directory")
            visited.add(offset)
            named, ids = resource_unpack("<HH", offset + 12)
            if named + ids > 256:
                raise ValueError("Installer resource directory has too many entries")
            for index in range(named + ids):
                name, target = resource_unpack("<II", offset + 16 + index * 8)
                if level == 0 and name != 16:
                    continue
                if target & 0x80000000:
                    walk(target & 0x7fffffff, level + 1)
                else:
                    if level != 2:
                        raise ValueError("Installer version resource has the wrong depth")
                    rva, size = resource_unpack("<II", target)
                    if not 8 <= size <= 1024 * 1024:
                        raise ValueError("Installer version resource is missing or too large")
                    begin = mapped(rva, size)
                    blocks(bytes(image[begin:begin + size]), 0, size)
        walk(0, 0)
        if not versions or len(set(versions)) != 1:
            raise ValueError("Installer has missing or conflicting ProductVersion strings")
        return versions[0]


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
    actual_version = product_version(args.installer)
    if actual_version != args.version:
        raise ValueError("Installer ProductVersion '" + actual_version + "' differs from --version '" + args.version + "'")
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
        if response.length:
            raise ValueError("Published response ended early")
        return data


def feed_bytes(feed):
    return fetch(feed + "?t=" + str(int(datetime.now(timezone.utc).timestamp())), 65536)


def live_feed(feed):
    data = feed_bytes(feed)
    return data, verify_manifest(data, feed_url=feed)


def released_versions():
    lines = [line.strip() for line in (ROOT / "tools/release/released-versions.txt").read_text(encoding="utf-8-sig").splitlines()]
    return [line for line in lines if line and not line.startswith("#")]


def release_floor(live_version):
    listed = max(released_versions(), key=precedence, default=None)
    return max((version for version in (listed, live_version) if version), key=precedence, default=None), listed


def record_release(version):
    path = ROOT / "tools/release/released-versions.txt"
    if version in released_versions():
        return
    text = path.read_text(encoding="utf-8-sig")
    with path.open("a", encoding="utf-8", newline="") as out:
        out.write(("\n" if text and not text.endswith("\n") else "") + version + "\n")
    print("Added " + version + " to tools/release/released-versions.txt. Commit that line to main.")


def check_feed_path(feed, feed_path):
    if not re.fullmatch(r"u/[A-Za-z0-9_-]+/beta\.json", feed_path) or urlparse(feed).path != "/" + feed_path:
        raise ValueError("Feed path differs from the committed feed")


def check_online_installer(item):
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


def upload(commands):
    if not os.environ.get("BLOB_READ_WRITE_TOKEN"):
        raise ValueError("BLOB_READ_WRITE_TOKEN is missing from the environment")
    for index, command in enumerate(commands):
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if result.returncode:
            raise ValueError("Blob upload " + str(index + 1) + " failed with exit code " + str(result.returncode))


def publish(args):
    feed = (ROOT / "tools/release/update-feed.txt").read_text().strip()
    data = Path(args.manifest).read_bytes()
    payload = verify_manifest(data, args.installer, feed)
    if not re.fullmatch(r"b/[A-Za-z0-9_-]+/RooIndustries-OptimizationSuite-[0-9A-Za-z.+-]+-setup\.exe", args.installer_path):
        raise ValueError("Use an immutable b/<random>/<installer> path")
    check_feed_path(feed, args.feed_path)
    if urlparse(payload["installer"]["url"]).path != "/" + args.installer_path:
        raise ValueError("Installer path differs from the signed URL")
    current, live = live_feed(feed)
    floor, _ = release_floor(live["version"])
    if precedence(payload["version"]) <= precedence(floor):
        source = "the live beta " if precedence(floor) == precedence(live["version"]) else "the released version "
        raise ValueError("Version " + payload["version"] + " is not newer than " + source + floor + ", so testers who already have " + floor + " would not be offered it")
    rollback = Path(args.manifest).with_name(Path(args.manifest).stem + ".previous-live.json")
    rollback.write_bytes(current)
    print("Saved the live " + live["version"] + " manifest for rollback: " + str(rollback))
    commands = [
        ["vercel", "blob", "put", str(args.installer), "--access", "public", "--pathname", args.installer_path, "--content-type", "application/octet-stream"],
        ["vercel", "blob", "put", str(args.manifest), "--access", "public", "--pathname", args.feed_path, "--allow-overwrite", "--cache-control-max-age", "60", "--content-type", "application/json"],
    ]
    for command in commands:
        print(shlex.join(command))
    if not args.yes_publish:
        print("Dry run: nothing uploaded. Publishing requires --yes-publish and user authorization.")
        return
    upload(commands)
    remote, published = live_feed(feed)
    if remote != data:
        raise ValueError("Published feed has not propagated to the signed bytes yet")
    check_online_installer(published["installer"])
    print("Published manifest and installer verified over HTTPS.")
    try:
        record_release(payload["version"])
    except (OSError, ValueError) as error:
        print("Published, but couldn't add " + payload["version"] + " to released-versions.txt (" + str(error) + "); add it by hand.", file=sys.stderr)
        return 1


def set_feed(args):
    feed = (ROOT / "tools/release/update-feed.txt").read_text().strip()
    data = Path(args.manifest).read_bytes()
    payload = verify_manifest(data, feed_url=feed)
    check_feed_path(feed, args.feed_path)
    try:
        current = feed_bytes(feed)
    except (ValueError, OSError, HTTPException) as error:
        if not isinstance(error, HTTPError) or error.code != 404:
            raise ValueError("Couldn't read the live feed (" + str(error) + "); try again")
        current, live, state = None, None, "a live feed that does not verify (" + str(error) + ")"
    else:
        try:
            live = verify_manifest(current, feed_url=feed)
            state = "the live " + live["version"] + " manifest"
        except (ValueError, KeyError, TypeError, AttributeError, InvalidSignature) as error:
            current, live, state = None, None, "a live feed that does not verify (" + ("Invalid signature" if isinstance(error, InvalidSignature) else str(error)) + ")"
    if current == data:
        raise ValueError("The live feed already serves this manifest")
    floor, listed = release_floor(live and live["version"])
    if floor != listed and precedence(payload["version"]) < precedence(floor):
        raise ValueError("The live beta " + floor + " is not in released-versions.txt. Add it there before rolling back, so testers who already have " + floor + " are offered the next publish")
    check_online_installer(payload["installer"])
    print("Replacing " + state + " with version " + payload["version"] + ".")
    command = ["vercel", "blob", "put", str(args.manifest), "--access", "public", "--pathname", args.feed_path, "--allow-overwrite", "--cache-control-max-age", "60", "--content-type", "application/json"]
    print(shlex.join(command))
    if not args.yes_publish:
        print("Dry run: nothing uploaded. Changing the feed requires --yes-publish and user authorization.")
        return
    upload([command])
    remote, _ = live_feed(feed)
    if remote != data:
        raise ValueError("The feed has not propagated to the signed bytes yet")
    print("The feed now serves version " + payload["version"] + ", verified over HTTPS.")


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
    point = commands.add_parser("set-feed")
    for name in ("manifest", "feed-path"):
        point.add_argument("--" + name, required=True)
    point.add_argument("--yes-publish", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "manifest":
            manifest(args)
        elif args.command == "verify":
            payload = verify_manifest(Path(args.manifest).read_bytes(), args.installer, args.feed_url)
            print(json.dumps({"verified": True, "version": payload["version"], "installer": payload["installer"]}))
        elif args.command == "set-feed":
            set_feed(args)
        else:
            return publish(args) or 0
    except (ValueError, KeyError, TypeError, AttributeError, OSError, struct.error, InvalidSignature) as error:
        print("Update release refused: " + ("Invalid signature" if isinstance(error, InvalidSignature) else str(error)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
