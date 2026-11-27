"""Synchronize and publish WakeMeOps on a dedicated persistent volume."""
import fcntl
import gzip
import hashlib
from http.client import HTTPException
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from urllib.request import urlopen

ROOT = Path("/mirror")
ARCHIVE = ROOT / "archive"
UPSTREAM = "http://deb.wakemeops.com/wakemeops/"
SECTIONS = ("devops", "terminal")


def package_hashes(snapshot):
    packages = {}
    for index in snapshot.glob("stable/*/binary-*/Packages"):
        for stanza in index.read_bytes().strip().split(b"\n\n"):
            if not stanza:
                continue
            fields = dict(re.findall(rb"^(Filename|SHA256): ([^\r\n]+)", stanza, re.MULTILINE))
            name = fields.get(b"Filename", b"").decode()
            digest = fields.get(b"SHA256", b"").decode()
            if not name.startswith("pool/") or ".." in Path(name).parts or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError(f"Invalid package record in {index}: {name!r}")
            if packages.setdefault(name, digest) != digest:
                raise ValueError(f"Conflicting SHA256 values for {name}")
    if not packages:
        raise ValueError(f"No binary packages found in {snapshot}")
    return packages


def complete_indexes(snapshot, architectures):
    # debmirror fetches gzip and xz. WakeMeOps also signs bz2 indexes, which
    # APT clients may request. Serve the exact bytes listed in the Release.
    release = subprocess.check_output([
        "gpgv", "--keyring", "/usr/share/keyrings/wakemeops.gpg", "--output", "-",
        str(snapshot / "stable/InRelease"),
    ]).decode()
    hashes = {}
    for line in release.split("SHA256:\n", 1)[1].splitlines():
        if not line.startswith(" "):
            break
        digest, _, name = line.split()
        hashes[name] = digest

    for section in SECTIONS:
        for arch in architectures:
            prefix = f"{section}/binary-{arch}/Packages"
            if prefix not in hashes:
                raise ValueError(f"Missing signed index for {section}/{arch}")
            plain = snapshot / "stable" / prefix
            # debmirror normally keeps only the compressed copy in dists/.
            if not plain.is_file():
                with gzip.open(plain.with_suffix(".gz"), "rb") as stream:
                    plain.write_bytes(stream.read())
            if hashlib.sha256(plain.read_bytes()).hexdigest() != hashes[prefix]:
                raise ValueError(f"Wrong SHA256 for {prefix}")
            name = prefix + ".bz2"
            if name in hashes:
                with urlopen(UPSTREAM + "dists/stable/" + name, timeout=60) as response:
                    data = response.read()
                if hashlib.sha256(data).hexdigest() != hashes[name]:
                    raise ValueError(f"Wrong SHA256 for {name}")
                (snapshot / "stable" / name).write_bytes(data)


def download_archive(architectures):
    command = [
        "debmirror", "--verbose", "--method=http", "--host=deb.wakemeops.com", "--root=wakemeops",
        "--dist=stable", "--section=" + ",".join(SECTIONS), "--arch=" + ",".join(architectures),
        "--nosource", "--rsync-extra=none", "--diff=none", "--slow-cpu", "--getcontents",
        "--check-gpg", "--keyring=/usr/share/keyrings/wakemeops.gpg", "--checksums",
        "--postcleanup", "--ignore=^pool/", "--timeout=60", str(ARCHIVE),
    ]
    # debmirror exits 1 even when its only failures are 404s for indexed .debs.
    # Accept only its complete final error summary; earlier errors can concern
    # signatures, metadata, transport or disk writes and must stay fatal.
    errors = None
    fetched = set()
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, errors="replace", env={**os.environ, "LC_ALL": "C"}) as process:
        for line in process.stdout:
            print(line, end="", flush=True)
            message = line.strip()
            if message == "Errors:":
                errors = []
            elif errors is not None:
                errors.append(message)
            match = re.match(r"^\[\s*\d+%\] Getting: (pool/\S+\.deb)\.\.\.", message)
            if match:
                fetched.add(match[1])
        status = process.wait()
    if status == 0:
        return fetched, set()
    if status == 1 and errors and len(errors) > 1:
        problems = errors[:-1]
        missing = [re.fullmatch(r"Download of (pool/\S+\.deb) failed: 404(?: [^\r\n]*)?", item) for item in problems]
        if all(missing) and errors[-1] == f"Failed to download files ({len(problems)} errors)!":
            return fetched, {match[1] for match in missing}
    raise subprocess.CalledProcessError(status, command)


def sync(architectures):
    fetched, missing = download_archive(architectures)

    # Only metadata is copied. Keep one pool of packages on the Unraid share.
    current = ROOT / "current"
    previous = current.resolve() if current.is_symlink() else None
    slot_a, slot_b = ROOT / "indexes-a", ROOT / "indexes-b"
    stage = slot_b if previous == slot_a else slot_a
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(ARCHIVE / "dists", stage)
    complete_indexes(stage, architectures)
    packages = package_hashes(stage)
    absent = {name for name in packages if not (ARCHIVE / name).is_file()}
    if absent != missing or len(absent) == len(packages):
        raise ValueError(f"Pool does not match the verified indexes: {len(absent)} missing, {len(missing)} reported 404")
    # --checksums verifies existing files. Also verify newly transferred payloads
    # against the signed indexes before making their versions available to APT.
    for name in fetched - missing:
        if name not in packages:
            raise ValueError(f"Downloaded package missing from signed indexes: {name}")
        package = ARCHIVE / name
        with package.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != packages[name]:
            package.unlink()
            raise ValueError(f"Wrong SHA256 for {name}")

    keep = set(packages)
    if previous:
        keep.update(package_hashes(previous))

    pending = ROOT / ".next"
    pending.unlink(missing_ok=True)
    pending.symlink_to(stage.name)
    pending.replace(current)

    # Clean only managed packages, after publication. Clients with the previous
    # indexes can still finish their downloads across a mirror update.
    for package in (ARCHIVE / "pool").rglob("*.deb"):
        if package.relative_to(ARCHIVE).as_posix() not in keep:
            package.unlink()
    return missing


def main():
    arches = os.environ.get("MIRROR_ARCHITECTURES", "amd64").split(",")
    if any(arch not in {"amd64", "arm64", "armhf"} for arch in arches):
        sys.exit("MIRROR_ARCHITECTURES must contain amd64, arm64 or armhf, separated by commas")
    with (ROOT / ".writer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        while True:
            print("Synchronizing WakeMeOps for", ", ".join(arches), flush=True)
            try:
                missing = sync(arches)
            except (OSError, HTTPException, ValueError, IndexError, subprocess.CalledProcessError) as exc:
                print(f"Synchronization failed: {exc}. Retrying in one hour.", file=sys.stderr, flush=True)
                time.sleep(3600)
            else:
                if missing:
                    print(f"Upstream returned 404 for {len(missing)} package file(s):", flush=True)
                    for name in sorted(missing):
                        print(f"  {name}", flush=True)
                print("Mirror published. Next sync in 24 hours.", flush=True)
                time.sleep(86400)


if __name__ == "__main__":
    main()
