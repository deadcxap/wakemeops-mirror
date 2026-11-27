#!/bin/bash
# Exercise the published layout with real APT, debmirror and a signed fixture.
set -euo pipefail
image=${1:?Pass the locally built image tag}
tmp=$(mktemp -d)
network="mirror-test-$$"
mirror="client-$$"
origin="origin-$$"
cleanup() {
    docker logs --tail 60 "$mirror" || true
    docker logs --tail 12 "$origin" || true
    docker rm -fv "$mirror" "$origin" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT
export GNUPGHOME="$tmp/gpg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key 'Mirror fixture <fixture@example.invalid>' ed25519 sign 1d
gpg --export > "$tmp/test.gpg"
repo="$tmp/origin/wakemeops"
mkdir -p "$repo/pool" "$tmp/package/DEBIAN"
cat > "$tmp/package/DEBIAN/control" <<'CONTROL'
Package: mirror-fixture
Version: 1
Architecture: amd64
Maintainer: Fixture <fixture@example.invalid>
Description: APT mirror smoke test
CONTROL
dpkg-deb --root-owner-group --build "$tmp/package" "$repo/pool/mirror-fixture.deb" >/dev/null
sed -i 's/^Package: mirror-fixture$/Package: mirror-gap/' "$tmp/package/DEBIAN/control"
dpkg-deb --root-owner-group --build "$tmp/package" "$repo/pool/mirror-gap.deb" >/dev/null
(
    cd "$repo"
    for section in devops terminal; do
        dir="dists/stable/$section/binary-amd64"
        mkdir -p "$dir"
        dpkg-scanpackages pool /dev/null > "$dir/Packages"
        gzip -nc "$dir/Packages" > "$dir/Packages.gz"
        bzip2 -c "$dir/Packages" > "$dir/Packages.bz2"
    done
    cd dists/stable
    {
        printf 'Origin: fixture\nLabel: fixture\nSuite: stable\nCodename: stable\n'
        printf 'Date: %s\nArchitectures: amd64\nComponents: devops terminal\n' "$(date -Ru)"
        for algo in md5 sha256; do
            if [ "$algo" = md5 ]; then echo MD5Sum:; else echo SHA256:; fi
            for file in */binary-amd64/Packages*; do
                digest=$("${algo}sum" "$file")
                printf ' %s %s %s\n' "${digest%% *}" "$(stat -c %s "$file")" "$file"
            done
        done
    } > Release
    gpg --batch --clearsign --output InRelease Release
    gpg --batch --armor --detach-sign --output Release.gpg Release
)
# The upstream index advertises a version that has disappeared from its pool.
mv "$repo/pool/mirror-gap.deb" "$tmp/gap.deb"
chmod -R a+rX "$tmp/origin"
docker network create --internal "$network" >/dev/null
docker run -d --name "$origin" --network "$network" --network-alias deb.wakemeops.com \
    -v "$tmp/origin:/upstream:ro" --entrypoint python3 "$image" \
    -m http.server 80 --directory /upstream >/dev/null
docker run -d --name "$mirror" --network "$network" \
    -v "$tmp/test.gpg:/usr/share/keyrings/wakemeops.gpg:ro" "$image" >/dev/null

for attempt in {1..60}; do
    [ "$(docker inspect -f '{{.State.Running}}' "$mirror")" = true ] || exit 1
    if docker logs "$mirror" 2>&1 | grep -F 'Retrying in one hour' >/dev/null; then exit 1; fi
    if docker exec "$mirror" test -s /mirror/current/stable/InRelease; then break; fi
    sleep 1
done
docker exec "$mirror" cmp /mirror/current/stable/terminal/binary-amd64/Packages.bz2 \
    /mirror/current/stable/devops/binary-amd64/Packages.bz2
docker exec -u 0 "$mirror" sh -ec '
    cd /tmp
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/wakemeops.gpg] http://127.0.0.1:8080/wakemeops/ stable devops terminal" > smoke.list
    apt-get -o Dir::Etc::sourcelist=/tmp/smoke.list -o Dir::Etc::sourceparts=- -o APT::Update::Error-Mode=any update
    apt-get -o Dir::Etc::sourcelist=/tmp/smoke.list -o Dir::Etc::sourceparts=- download mirror-fixture
    dpkg-deb -f mirror-fixture_1_amd64.deb Package | grep -x mirror-fixture
'
docker logs "$mirror" 2>&1 | grep -F '404 for 1 package file(s)' >/dev/null
original=$(docker exec "$mirror" readlink /mirror/current)
wait_for_log() {
    for attempt in {1..45}; do
        if docker logs --since "$since" "$mirror" 2>&1 | grep -F "$1" >/dev/null; then return 0; fi
        sleep 1
    done
    return 1
}

# A different payload at the missing path is an integrity failure, even on
# first download. Keep the previously published indexes.
printf 'wrong package' > "$repo/pool/mirror-gap.deb"
since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
docker restart "$mirror" >/dev/null
wait_for_log 'Retrying in one hour'
test "$(docker exec "$mirror" readlink /mirror/current)" = "$original"
docker exec "$mirror" test ! -e /mirror/archive/pool/mirror-gap.deb

# A corrected upstream copy is recovered on the next pass; reuse cached .debs.
mv "$tmp/gap.deb" "$repo/pool/mirror-gap.deb"
since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
docker restart "$mirror" >/dev/null
wait_for_log 'Mirror published. Next sync in 24 hours.'
test "$(docker exec "$mirror" readlink /mirror/current)" != "$original"
docker exec -u 0 "$mirror" sh -ec '
    cd /tmp
    apt-get -o Dir::Etc::sourcelist=/tmp/smoke.list -o Dir::Etc::sourceparts=- download mirror-gap
    dpkg-deb -f mirror-gap_1_amd64.deb Package | grep -x mirror-gap
'
test "$(docker logs "$origin" 2>&1 | grep -c 'GET /wakemeops/pool/mirror-fixture.deb ')" -eq 1

# Invalid upstream signatures must leave the last good publication in service.
printf 'invalid' > "$repo/dists/stable/InRelease"
printf 'invalid' > "$repo/dists/stable/Release.gpg"
since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
docker restart "$mirror" >/dev/null
wait_for_log 'Retrying in one hour'
docker exec "$mirror" sh -ec 'cd /tmp && python3 -c "from urllib.request import urlretrieve; urlretrieve(\"http://127.0.0.1:8080/wakemeops/dists/stable/InRelease\", \"served\")" && gpgv --keyring /usr/share/keyrings/wakemeops.gpg served'
