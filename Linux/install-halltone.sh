#!/usr/bin/env bash
# Adds the Halltone apt repo (on the LAN, Proxmox container "apt") and installs halltone-linux,
# then starts it as your user service. Safe to run again: it also upgrades to the newest release.
set -euo pipefail

# Run as yourself, not with sudo: it uses sudo itself where needed, and the Halltone service,
# its top-bar icon and log shipping are per-user (systemctl --user).
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user (double-click it, or ./install-halltone.sh), not with sudo or as root." >&2
  exit 1
fi

# HALLTONE_SERVER and HALLTONE_FINGERPRINT exist for tests (CI points them at a throwaway repo).
SERVER="${HALLTONE_SERVER:-http://apt.localdomain}"
REPO_URL="$SERVER/halltone"
KEYRING="/usr/share/keyrings/halltone-archive-keyring.gpg"
FINGERPRINT="${HALLTONE_FINGERPRINT:-CC986414E18AB806302DEA35935DEAC147677FAF}"
SOURCES="/etc/apt/sources.list.d/halltone.sources"

say() { printf '\n==> %s\n' "$*"; }

# Downloads the repo's public key to $1 and checks it is the pinned one.
fetch_keyring() {
  local got
  curl -fsSL -m 20 "$REPO_URL/halltone-archive-keyring.gpg" -o "$1" || return 1
  got=$(gpg --show-keys --with-colons "$1" 2>/dev/null | awk -F: '/^fpr/ && !f {print $10; f=1}')
  if [ "$got" != "$FINGERPRINT" ]; then
    echo "The key served by $REPO_URL has fingerprint '$got', expected $FINGERPRINT. Not installing." >&2
    return 1
  fi
}

# Self-update: the server publishes the newest installer (signed by the repo key) at
# $SERVER/install-halltone.sh. If it differs from this copy, run that one instead and, where
# possible, replace this file with it so the copy on your desktop never goes stale. Any failure
# (server down, bad signature, ...) just carries on with this copy. HALLTONE_SELF_UPDATED stops
# the re-exec'd copy from updating again, so it can never loop.
# The placeholder pattern below is written with a bracket so it does not match its own line.
PLACEHOLDER_LINE='^LOG_TOKEN="__LOG_[T]OKEN__"$'
fetch_published_installer() {  # $1 = scratch dir; leaves $1/new verified
  curl -fsS -m 15 "$SERVER/install-halltone.sh" -o "$1/new" || return 1
  curl -fsS -m 15 "$SERVER/install-halltone.sh.asc" -o "$1/new.asc" || return 1
  fetch_keyring "$1/key.gpg" || return 1
  gpgv --keyring "$1/key.gpg" "$1/new.asc" "$1/new" 2>/dev/null || { echo "signature check failed" >&2; return 1; }
  bash -n "$1/new" || return 1
  if grep -q "$PLACEHOLDER_LINE" "$1/new"; then echo "published copy has no log token" >&2; return 1; fi
}
self_update() {
  local self="${BASH_SOURCE[0]:-}" d target
  [ -z "${HALLTONE_SELF_UPDATED:-}" ] || return 0
  [ -f "$self" ] || return 0   # piped into bash (`curl ... | bash`): already the latest
  if ! command -v gpgv >/dev/null || ! command -v gpg >/dev/null; then echo "(gpg missing: skipping installer self-update)"; return 0; fi
  d=$(mktemp -d)
  if ! fetch_published_installer "$d" >/dev/null; then
    echo "(could not fetch a verified newer installer from $SERVER: continuing with this copy)"
    rm -rf "$d"; return 0
  fi
  if cmp -s "$self" "$d/new"; then rm -rf "$d"; return 0; fi
  say "Updating the installer from $SERVER and restarting it"
  chmod 755 "$d/new"
  target="$d/new"
  # Replace this file unless it is the git template (placeholder token): never write the real token into a checkout.
  if ! grep -q "$PLACEHOLDER_LINE" "$self" && cp "$d/new" "$self.new" 2>/dev/null && mv -f "$self.new" "$self" 2>/dev/null; then
    target="$self"
  fi
  HALLTONE_SELF_UPDATED=1 exec bash "$target" "$@"
}
self_update "$@"

# Diagnostics: this run's output (success or failure) goes to the log receiver on the LAN repo
# server (apt.localdomain), so problems can be fixed without copy-pasting. LAN only.
LOG_URL="$SERVER/halltone-logs"
LOG_TOKEN="__LOG_TOKEN__"
runlog=$(mktemp)
exec > >(tee -a "$runlog") 2>&1
teepid=$!
upload_run_log() {
  local rc=$?
  {
    echo "installer exit=$rc user=$USER date=$(date -Is)"
    grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null
    echo "arch=$(dpkg --print-architecture) foreign=$(dpkg --print-foreign-architectures | tr '\n' ' ')"
    echo "installed=$(dpkg-query -W -f='${Version}' halltone-linux 2>/dev/null || echo none)"
    echo "----- output -----"
  } > "$runlog.hdr"
  exec 1>&- 2>&-
  wait "$teepid" 2>/dev/null || true
  cat "$runlog.hdr" "$runlog" | curl -fsS -m 15 -H "X-Halltone-Log-Token: $LOG_TOKEN" \
    -H "X-Halltone-Host: $(hostname)" --data-binary @- "$LOG_URL/install" >/dev/null 2>&1 || true
  rm -f "$runlog" "$runlog.hdr" "${tmp:-}"
}
trap upload_run_log EXIT

say "Fetching the repo signing key"
tmp=$(mktemp)
fetch_keyring "$tmp" || exit 1
sudo install -m 644 "$tmp" "$KEYRING"

say "Adding the repo ($SOURCES)"
sudo tee "$SOURCES" >/dev/null <<SRC
Types: deb
URIs: $REPO_URL
Suites: stable
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: $KEYRING
SRC

say "Installing halltone-linux"
sudo apt-get update
candidate=$(LC_ALL=C apt-cache policy halltone-linux | sed -n 's/^ *Candidate: *//p')
if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
  echo "The repo has no halltone-linux package yet (the first release may not be published)." >&2
  echo "Run this script again later." >&2
  exit 1
fi
sudo apt-get install -y halltone-linux

say "Setting up log shipping (halltone service logs -> apt.localdomain, every 5 min)"
mkdir -p "$HOME/.local/bin" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
cat > "$HOME/.local/bin/halltone-log-ship" <<SHIP
#!/usr/bin/env bash
# Sends new halltone service log lines to the LAN repo server's log receiver.
# Disable with: systemctl --user disable --now halltone-log-ship.timer
set -uo pipefail
URL="$LOG_URL/service"
TOKEN="$LOG_TOKEN"
SHIP
cat >> "$HOME/.local/bin/halltone-log-ship" <<'SHIP'
state="${XDG_STATE_HOME:-$HOME/.local/state}/halltone"
mkdir -p "$state"
cur="$state/log-cursor"
args=(--user -u halltone -o short-iso --no-pager --show-cursor)
if [ -s "$cur" ]; then args+=("--after-cursor=$(cat "$cur")"); else args+=(--since=-1h); fi
out=$(journalctl "${args[@]}" 2>&1)
newcur=$(printf '%s\n' "$out" | sed -n 's/^-- cursor: //p' | tail -n 1)
body=$(printf '%s\n' "$out" | grep -v -e '^-- cursor: ' -e '^-- No entries --$')
if [ -n "$body" ]; then
  ver=$(dpkg-query -W -f='${Version}' halltone-linux 2>/dev/null)
  printf 'version=%s\n%s\n' "$ver" "$body" | tail -c 4500000 | curl -fsS -m 20 \
    -H "X-Halltone-Log-Token: $TOKEN" -H "X-Halltone-Host: $(hostname)" --data-binary @- "$URL" >/dev/null || exit 0
fi
[ -n "$newcur" ] && printf '%s\n' "$newcur" > "$cur"
exit 0
SHIP
chmod 700 "$HOME/.local/bin/halltone-log-ship"
cat > "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/halltone-log-ship.service" <<'UNIT'
[Unit]
Description=Send halltone logs to the LAN repo server
[Service]
Type=oneshot
ExecStart=%h/.local/bin/halltone-log-ship
UNIT
cat > "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/halltone-log-ship.timer" <<'UNIT'
[Unit]
Description=Send halltone logs to the LAN repo server every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT

if systemctl --user show-environment >/dev/null 2>&1; then
say "Starting Halltone for $USER"
systemctl --user daemon-reload
systemctl --user enable --now halltone
systemctl --user enable --now halltone-log-ship.timer
systemctl --user restart halltone   # picks up an upgrade
# Top-bar icon: starts at every login; start it now too if a desktop session is running.
# (command substitution rather than `grep -q`: a pipe closed early would trip pipefail.)
# shellcheck disable=SC2143
if command -v halltone-tray >/dev/null && [ -n "$(systemctl --user show-environment 2>/dev/null | grep -E '^(WAYLAND_DISPLAY|DISPLAY)=')" ]; then
  pkill -u "$USER" -f /usr/bin/halltone-tray 2>/dev/null || true
  systemd-run --user --collect --unit="halltone-tray-$(date +%s)" /usr/bin/halltone-tray >/dev/null 2>&1 || true
fi
sleep 2
systemctl --user --no-pager --lines=5 status halltone || true
else
  echo "Skipping the user service, log-ship timer and tray: no systemd user session here (container or ssh without a login session)."
  echo "Log in on the desktop and run this script again to start them."
fi

config="${XDG_CONFIG_HOME:-$HOME/.config}/halltone/config.json"
if [ -f "$config" ]; then
  code=$(sed -n 's/.*"pairingCode"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]\{4\}\).*/\1/p;T;q' "$config")
  [ -n "$code" ] && say "Pairing code: $code  (enter it in Halltone on the iPhone)"
fi
say "Done. Logs: journalctl --user -u halltone -f"
