#!/bin/bash
# Exercise the published layout with real APT, debmirror and a signed fixture.
set -euo pipefail
image=${1:?Pass the locally built image tag}
tmp=$(mktemp -d)
network="mirror-test-$$"
mirror="client-$$"
origin="origin-$$"
cleanup() {
    docker logs --tail 60 "$mirror" 2>/dev/null || true
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
dpkg-deb --build "$tmp/package" "$repo/pool/mirror-fixture.deb" >/dev/null
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
chmod -R a+rX "$tmp/origin"
docker network create --internal "$network" >/dev/null
docker run -d --name "$origin" --network "$network" --network-alias deb.wakemeops.com \
    -v "$tmp/origin:/upstream:ro" --entrypoint python3 "$image" \
    -m http.server 80 --directory /upstream >/dev/null
docker run -d --name "$mirror" --network "$network" \
    -v "$tmp/test.gpg:/usr/share/keyrings/wakemeops.gpg:ro" "$image" >/dev/null

for attempt in {1..60}; do
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
# Invalid upstream signatures must leave the last good publication in service.
printf 'invalid' > "$repo/dists/stable/InRelease"
printf 'invalid' > "$repo/dists/stable/Release.gpg"
docker restart "$mirror" >/dev/null
for attempt in {1..45}; do
    if docker logs "$mirror" 2>&1 | grep -F 'Retrying in one hour' >/dev/null; then break; fi
    sleep 1
done
docker logs "$mirror" 2>&1 | grep -F 'Retrying in one hour' >/dev/null
docker exec "$mirror" sh -ec 'cd /tmp && python3 -c "from urllib.request import urlretrieve; urlretrieve(\"http://127.0.0.1:8080/wakemeops/dists/stable/InRelease\", \"served\")" && gpgv --keyring /usr/share/keyrings/wakemeops.gpg served'
