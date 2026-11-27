#!/bin/bash
# CI test for Linux/install-halltone.sh. Run as root in a clean ubuntu:24.04 container.
# Builds a throwaway signed apt repo (reprepro) with stub halltone-linux .debs, serves it with
# fake-server.py, and runs the installer as an ordinary user: install, self-update, upgrade,
# and the guards (not root, wrong fingerprint, bad signature, no self-update loop).
# The stub .debs stand in for the CI-built package, whose real install test is linux-deb.yml.
set -euo pipefail
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$HERE/../../install-halltone.sh"
W=/srv/w; PORT=8080; TOKEN=ci-test-token-0123456789abcdef
ok()   { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }

apt-get update -qq
apt-get install -y -qq --no-install-recommends sudo curl gnupg gpgv reprepro python3 ca-certificates dpkg-dev >/dev/null
ARCH=$(dpkg --print-architecture)

mkdir -p "$W/www/halltone/conf"
export GNUPGHOME=/root/gnupg; install -d -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key "ci repo <ci@example.invalid>" ed25519 sign 1d 2>/dev/null
FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
gpg --export "$FPR" > "$W/www/halltone/halltone-archive-keyring.gpg"
printf 'Origin: Halltone\nSuite: stable\nCodename: stable\nArchitectures: %s\nComponents: main\nSignWith: %s\n' "$ARCH" "$FPR" > "$W/www/halltone/conf/distributions"

make_deb() {  # version
  local d; d=$(mktemp -d); mkdir -p "$d/DEBIAN" "$d/usr/bin"
  printf 'Package: halltone-linux\nVersion: %s\nArchitecture: %s\nSection: sound\nPriority: optional\nMaintainer: ci <ci@example.invalid>\nDescription: stub of halltone-linux for installer tests\n' "$1" "$ARCH" > "$d/DEBIAN/control"
  printf '#!/bin/sh\necho "halltone-linux %s"\n' "$1" > "$d/usr/bin/halltone-linux"; chmod 755 "$d/usr/bin/halltone-linux"
  dpkg-deb --build "$d" "$W/halltone-linux_$1_$ARCH.deb" >/dev/null
  reprepro -b "$W/www/halltone" includedeb stable "$W/halltone-linux_$1_$ARCH.deb" >/dev/null
}
publish() {  # [extra lines appended before signing] : same steps as halltone-publish-installer
  sed "s|^LOG_TOKEN=\"__LOG_TOKEN__\"\$|LOG_TOKEN=\"$TOKEN\"|" "$INSTALLER" > "$W/www/install-halltone.sh"
  [ -z "${1:-}" ] || echo "# $1" >> "$W/www/install-halltone.sh"
  rm -f "$W/www/install-halltone.sh.asc"
  gpg --batch --armor --detach-sign -o "$W/www/install-halltone.sh.asc" "$W/www/install-halltone.sh"
}
make_deb 1.0.0
publish
python3 "$HERE/fake-server.py" "$W/www" "$PORT" > "$W/server.out" 2>&1 &
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done

useradd -m -s /bin/bash tester
echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester
export HALLTONE_SERVER="http://127.0.0.1:$PORT" HALLTONE_FINGERPRINT="$FPR"
as_tester() { runuser -u tester -- env -u GNUPGHOME HOME=/home/tester USER=tester LOGNAME=tester HALLTONE_SERVER="$HALLTONE_SERVER" HALLTONE_FINGERPRINT="${FPR_OVERRIDE:-$HALLTONE_FINGERPRINT}" "$@"; }
# An installed copy as the owner would have it: the git file with an old token substituted.
fresh_copy() { sed "s|^LOG_TOKEN=\"__LOG_TOKEN__\"\$|LOG_TOKEN=\"old-token\"|" "$INSTALLER" > /home/tester/install-halltone.sh; chown tester:tester /home/tester/install-halltone.sh; chmod 755 /home/tester/install-halltone.sh; }

echo "### not root"
if out=$(HALLTONE_SERVER=http://127.0.0.1:1 bash "$INSTALLER" 2>&1); then fail "ran as root"; fi
grep -q 'not with sudo or as root' <<<"$out" && ok "refuses to run as root, before touching anything"
[ ! -e /etc/apt/sources.list.d/halltone.sources ] || fail "root run changed apt sources"

echo "### install + self-update (desktop copy has an old token)"
fresh_copy
as_tester /home/tester/install-halltone.sh 2>&1 | tee "$W/run1.out"
grep -q 'Updating the installer' "$W/run1.out" && ok "newer published installer detected and re-exec'd"
grep -q "^LOG_TOKEN=\"$TOKEN\"\$" /home/tester/install-halltone.sh && ok "desktop copy replaced with the published one"
[ "$(dpkg-query -W -f='${Version}' halltone-linux)" = 1.0.0 ] && ok "halltone-linux 1.0.0 installed"
grep -q "^Architectures: $ARCH\$" /etc/apt/sources.list.d/halltone.sources && ok "source pinned to dpkg architecture"
grep -q 'Skipping the user service' "$W/run1.out" && ok "no systemd user session: skipped with a clear message"
for f in .local/bin/halltone-log-ship .config/systemd/user/halltone-log-ship.timer .config/systemd/user/halltone-log-ship.service; do
  [ -f "/home/tester/$f" ] || fail "missing $f"
done
grep -q "^TOKEN=\"$TOKEN\"\$" /home/tester/.local/bin/halltone-log-ship && ok "log-ship helper written with the token"
grep -q "token=$TOKEN host=" "$W/uploads.log" && grep -q 'installer exit=0' "$W/uploads.log" && ok "run log uploaded on exit with the token"

echo "### same installer, newer package: upgrade, no self-update"
make_deb 2.0.0
as_tester /home/tester/install-halltone.sh 2>&1 | tee "$W/run2.out"
[ "$(dpkg-query -W -f='${Version}' halltone-linux)" = 2.0.0 ] && ok "upgraded to 2.0.0"
if grep -q 'Updating the installer' "$W/run2.out"; then fail "updated although up to date"; fi
ok "up-to-date installer does not re-exec"

echo "### installer changes on the server: picked up, once"
publish "newer revision"
as_tester /home/tester/install-halltone.sh 2>&1 | tee "$W/run3.out"
[ "$(grep -c 'Updating the installer' "$W/run3.out")" = 1 ] && tail -n1 /home/tester/install-halltone.sh | grep -q 'newer revision' && ok "updated exactly once (no loop)"

echo "### loop guard: HALLTONE_SELF_UPDATED set"
fresh_copy
as_tester env HALLTONE_SELF_UPDATED=1 /home/tester/install-halltone.sh 2>&1 | tee "$W/run4.out"
if grep -q 'Updating the installer' "$W/run4.out"; then fail "updated despite guard"; fi
grep -q 'old-token' /home/tester/install-halltone.sh && ok "guard prevents a second update"

echo "### git template is never overwritten with the token"
cp "$INSTALLER" /home/tester/template.sh; chown tester:tester /home/tester/template.sh
as_tester bash /home/tester/template.sh 2>&1 | tee "$W/run5.out"
grep -q 'Updating the installer' "$W/run5.out" && cmp -s "$INSTALLER" /home/tester/template.sh && ok "template run used the published copy, file untouched"

echo "### bad signature: self-update refused, install still proceeds"
publish; echo '# tampered after signing' >> "$W/www/install-halltone.sh"
fresh_copy
as_tester /home/tester/install-halltone.sh 2>&1 | tee "$W/run6.out"
grep -q 'continuing with this copy' "$W/run6.out" && grep -q 'old-token' /home/tester/install-halltone.sh && ok "tampered installer not run"
publish

echo "### wrong key fingerprint"
fresh_copy
if FPR_OVERRIDE=0000000000000000000000000000000000000000 as_tester /home/tester/install-halltone.sh > "$W/run7.out" 2>&1; then fail "accepted wrong fingerprint"; fi
grep -q 'Not installing' "$W/run7.out" && ok "wrong fingerprint refused"
grep -q 'installer exit=1' "$W/uploads.log" && ok "failed run also uploads its log"
echo "ALL INSTALLER TESTS PASSED"
