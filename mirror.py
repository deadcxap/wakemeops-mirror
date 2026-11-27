"""Synchronize and publish WakeMeOps on a dedicated persistent volume."""
import fcntl
import hashlib
from http.client import HTTPException
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from urllib.request import urlopen

ROOT = Path("/mirror")
ARCHIVE = ROOT / "archive"
UPSTREAM = "http://deb.wakemeops.com/wakemeops/"
SECTIONS = ("devops", "terminal")


def package_names(snapshot):
    names = set()
    for index in snapshot.glob("stable/*/binary-*/Packages"):
        with index.open("rb") as stream:
            names.update(line[10:].strip().decode() for line in stream if line.startswith(b"Filename: "))
    if not names:
        raise ValueError(f"No binary packages found in {snapshot}")
    return names


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
            if prefix not in hashes or not (snapshot / "stable" / prefix).is_file():
                raise ValueError(f"Missing signed index for {section}/{arch}")
            name = prefix + ".bz2"
            if name in hashes:
                with urlopen(UPSTREAM + "dists/stable/" + name, timeout=60) as response:
                    data = response.read()
                if hashlib.sha256(data).hexdigest() != hashes[name]:
                    raise ValueError(f"Wrong SHA256 for {name}")
                (snapshot / "stable" / name).write_bytes(data)


def sync(architectures):
    subprocess.run([
        "debmirror", "--method=http", "--host=deb.wakemeops.com", "--root=wakemeops",
        "--dist=stable", "--section=" + ",".join(SECTIONS), "--arch=" + ",".join(architectures),
        "--nosource", "--rsync-extra=none", "--diff=none", "--slow-cpu", "--getcontents",
        "--check-gpg", "--keyring=/usr/share/keyrings/wakemeops.gpg", "--checksums",
        "--postcleanup", "--ignore=^pool/", "--timeout=60", str(ARCHIVE),
    ], check=True)

    # Only metadata is copied. Keep one pool of packages on the Unraid share.
    current = ROOT / "current"
    previous = current.resolve() if current.is_symlink() else None
    slot_a, slot_b = ROOT / "indexes-a", ROOT / "indexes-b"
    stage = slot_b if previous == slot_a else slot_a
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(ARCHIVE / "dists", stage)
    complete_indexes(stage, architectures)
    keep = package_names(stage)
    if previous:
        keep.update(package_names(previous))

    pending = ROOT / ".next"
    pending.unlink(missing_ok=True)
    pending.symlink_to(stage.name)
    pending.replace(current)

    # Clean only managed packages, after publication. Clients with the previous
    # indexes can still finish their downloads across a mirror update.
    for package in (ARCHIVE / "pool").rglob("*.deb"):
        if package.relative_to(ARCHIVE).as_posix() not in keep:
            package.unlink()


def main():
    arches = os.environ.get("MIRROR_ARCHITECTURES", "amd64").split(",")
    if any(arch not in {"amd64", "arm64", "armhf"} for arch in arches):
        sys.exit("MIRROR_ARCHITECTURES must contain amd64, arm64 or armhf, separated by commas")
    with (ROOT / ".writer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        while True:
            print("Synchronizing WakeMeOps for", ", ".join(arches), flush=True)
            try:
                sync(arches)
            except (OSError, HTTPException, ValueError, IndexError, subprocess.CalledProcessError) as exc:
                print(f"Synchronization failed: {exc}. Retrying in one hour.", file=sys.stderr, flush=True)
                time.sleep(3600)
            else:
                print("Mirror published. Next sync in 24 hours.", flush=True)
                time.sleep(86400)


if __name__ == "__main__":
    main()
