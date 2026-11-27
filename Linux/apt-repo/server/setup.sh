#!/bin/bash
# Sets up (or re-converges) the Halltone LAN apt repo server on a Debian 12 container:
#   - reprepro repo at /srv/apt/halltone (suite stable), signed by a key that only lives here
#   - halltone-repo-sync + 15-minute timer importing linux-v* GitHub releases (SHA256SUMS-checked)
#   - halltone-build-main + 5-minute timer building each new main commit (amd64) as user builder,
#     signed in by halltone-build-import (user repo); Swift toolchain in /opt/swift
#   - halltone-logrx, the LAN log receiver, behind nginx at /halltone-logs/<kind>
#   - nginx on :80, and the desktop installer published at /install-halltone.sh
#
# Idempotent: run it again after `git pull` to deploy changes. It never regenerates an existing
# signing key (/var/lib/repo/.gnupg) or log token (/etc/halltone-logrx/token).
#
# Usage (root, from a checkout of the repo):  Linux/apt-repo/server/setup.sh
set -euo pipefail
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALLER_SRC="${INSTALLER_SRC:-$HERE/../../install-halltone.sh}"
R=/srv/apt/halltone
GNUPGHOME=/var/lib/repo/.gnupg
TOKEN_FILE=/etc/halltone-logrx/token
# The Swift used to build main: same release as CI's swift:6.1-noble image, Debian 12 build,
# checked against the Swift 6.x release signing key.
SWIFT_VERSION=6.1.3
SWIFT_KEY_FPR=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
B=/var/lib/halltone-build

say() { printf '\n==> %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$INSTALLER_SRC" ] || { echo "installer not found at $INSTALLER_SRC" >&2; exit 1; }
have_systemd() { [ -d /run/systemd/system ]; }

# put SRC DEST MODE: install only when the content differs; sets CHANGED=1 when it did.
CHANGED=0
put() {
  if [ -f "$2" ] && cmp -s "$1" "$2" && [ "$(stat -c %a "$2")" = "$3" ]; then return 0; fi
  install -D -m "$3" "$1" "$2"; CHANGED=1
}
repo_run() { runuser -u repo -- env GNUPGHOME="$GNUPGHOME" "$@"; }

say "Packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends reprepro gnupg nginx curl jq python3 ca-certificates openssl >/dev/null
# Building halltone-linux: Swift's own runtime needs, then build-deb.sh's.
apt-get install -y -qq --no-install-recommends git binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-12-dev \
  libpython3-dev libsqlite3-0 libstdc++-12-dev libxml2-dev libz3-dev zlib1g-dev tzdata unzip \
  pkg-config libpulse-dev dpkg-dev util-linux >/dev/null

say "Users and directories"
id repo >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/repo --shell /usr/sbin/nologin repo
id halltonelog >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin halltonelog
mkdir -p "$R/conf" /var/lib/repo/state
chown -R repo:repo /srv/apt /var/lib/repo
install -d -o halltonelog -g halltonelog -m 750 /var/log/halltone-clients
install -d -m 755 /etc/halltone-logrx
id builder >/dev/null 2>&1 || useradd --system --create-home --home-dir "$B" --shell /usr/sbin/nologin builder
usermod -a -G builder repo   # the importer removes what it signed in from the outbox
install -d -o builder -g builder -m 755 "$B" "$B/state"
install -d -o builder -g builder -m 2775 "$B/outbox"
touch /var/lib/repo/reprepro.lock; chown repo:repo /var/lib/repo/reprepro.lock

say "Swift $SWIFT_VERSION toolchain (/opt/swift)"
if [ -n "${HALLTONE_SKIP_SWIFT:-}" ]; then
  echo "HALLTONE_SKIP_SWIFT set: skipping (CI)"
elif [ -x /opt/swift/usr/bin/swift ] && /opt/swift/usr/bin/swift --version 2>/dev/null | grep -q "Swift version $SWIFT_VERSION "; then
  echo "already installed"
else
  sw=$(mktemp -d)
  base="https://download.swift.org/swift-$SWIFT_VERSION-release/debian12/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE-debian12.tar.gz"
  curl -fsSL -o "$sw/swift.tar.gz" "$base"
  curl -fsSL -o "$sw/swift.tar.gz.sig" "$base.sig"
  curl -fsSL -o "$sw/keys.asc" https://www.swift.org/keys/all-keys.asc
  gpg --batch --no-default-keyring --keyring "$sw/swift.kbx" --import "$sw/keys.asc" 2>/dev/null
  gpg --batch --no-default-keyring --keyring "$sw/swift.kbx" --export "$SWIFT_KEY_FPR" > "$sw/key.gpg"
  [ -s "$sw/key.gpg" ] || { echo "Swift signing key $SWIFT_KEY_FPR not in all-keys.asc" >&2; exit 1; }
  gpgv --keyring "$sw/key.gpg" "$sw/swift.tar.gz.sig" "$sw/swift.tar.gz" || { echo "Swift toolchain signature check failed" >&2; exit 1; }
  rm -rf /opt/swift.new; mkdir -p /opt/swift.new
  tar -xzf "$sw/swift.tar.gz" -C /opt/swift.new --strip-components=1
  rm -rf /opt/swift; mv /opt/swift.new /opt/swift; rm -rf "$sw"
  /opt/swift/usr/bin/swift --version
fi

say "Signing key (kept if present)"
# No passphrase: signing runs unattended; the key never leaves this container (see the README to back it up).
install -d -o repo -g repo -m 700 "$GNUPGHOME"
if ! repo_run gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
  echo "No signing key found: generating a new one. Clients pin its fingerprint (see README)."
  repo_run gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Halltone apt repo (LAN) <apt@halltone.invalid>" ed25519 sign 10y
fi
FPR=$(repo_run gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
repo_run gpg --export "$FPR" > "$R/halltone-archive-keyring.gpg"
repo_run gpg --armor --export "$FPR" > "$R/halltone-archive-keyring.asc"

say "reprepro"
conf=$(mktemp); trap 'rm -f "$conf" "${conf}.opt"' EXIT
cat > "$conf" <<DIST
Origin: Halltone
Label: Halltone
Suite: stable
Codename: stable
Architectures: amd64 arm64 i386 armhf
Components: main
Description: Halltone Linux sender (releases from GitHub Actions; main builds made here)
SignWith: $FPR
DIST
printf 'verbose\nbasedir %s\n' "$R" > "${conf}.opt"
put "$conf" "$R/conf/distributions" 644
put "${conf}.opt" "$R/conf/options" 644
chown -R repo:repo /srv/apt
repo_run reprepro -b "$R" export stable >/dev/null

say "Release importer"
put "$HERE/halltone-repo-sync" /usr/local/bin/halltone-repo-sync 755
put "$HERE/systemd/halltone-repo-sync.service" /etc/systemd/system/halltone-repo-sync.service 644
put "$HERE/systemd/halltone-repo-sync.timer" /etc/systemd/system/halltone-repo-sync.timer 644

say "main builder"
put "$HERE/halltone-build-main" /usr/local/bin/halltone-build-main 755
put "$HERE/halltone-build-import" /usr/local/bin/halltone-build-import 755
for u in halltone-build.service halltone-build-import.service halltone-build.timer; do
  put "$HERE/systemd/$u" "/etc/systemd/system/$u" 644
done

say "Log receiver"
if [ ! -s "$TOKEN_FILE" ]; then
  echo "No log token found: generating one."
  (umask 077; openssl rand -hex 24 | tr -d '\n' > "$TOKEN_FILE")
fi
chown root:halltonelog "$TOKEN_FILE"; chmod 640 "$TOKEN_FILE"
CHANGED=0
put "$HERE/halltone-logrx" /usr/local/bin/halltone-logrx 755
put "$HERE/systemd/halltone-logrx.service" /etc/systemd/system/halltone-logrx.service 644
logrx_changed=$CHANGED

say "nginx"
put "$HERE/nginx/apt.conf" /etc/nginx/sites-available/apt 644
ln -sf /etc/nginx/sites-available/apt /etc/nginx/sites-enabled/apt
rm -f /etc/nginx/sites-enabled/default
nginx -t

say "Desktop installer"
install -d -m 755 /usr/local/share/halltone
put "$INSTALLER_SRC" /usr/local/share/halltone/install-halltone.sh 644
put "$HERE/install-halltone.desktop" /usr/local/share/halltone/install-halltone.desktop 644
put "$HERE/halltone-publish-installer" /usr/local/bin/halltone-publish-installer 755
# Always republish: cheap, and picks up a token change.
/usr/local/bin/halltone-publish-installer

say "Services"
if have_systemd; then
  systemctl daemon-reload
  systemctl enable --now halltone-repo-sync.timer
  if [ -x /opt/swift/usr/bin/swift ]; then systemctl enable --now halltone-build.timer; else systemctl disable --now halltone-build.timer 2>/dev/null || true; fi
  systemctl enable halltone-logrx >/dev/null
  if [ "$logrx_changed" = 1 ]; then systemctl restart halltone-logrx; else systemctl start halltone-logrx; fi
  systemctl enable nginx >/dev/null
  systemctl reload-or-restart nginx
  sleep 1
  systemctl is-active halltone-logrx nginx halltone-repo-sync.timer
  [ ! -x /opt/swift/usr/bin/swift ] || systemctl is-active halltone-build.timer
else
  echo "systemd is not running here (CI container?): units installed but not started."
fi

echo
echo "Done. Repo signing key fingerprint: $FPR"
# shellcheck disable=SC2016
want=$(sed -n 's/^FINGERPRINT="\${HALLTONE_FINGERPRINT:-\([0-9A-F]*\)}"$/\1/p' "$INSTALLER_SRC")
if [ -n "$want" ] && [ "$want" != "$FPR" ]; then
  cat >&2 <<WARN

WARNING: the installer pins fingerprint $want
         but this server signs with $FPR.
         Clients will refuse to install. Either restore the original key into $GNUPGHOME
         (README: "Backing up the signing key") or update FINGERPRINT in Linux/install-halltone.sh
         and rerun this script.
WARN
fi
