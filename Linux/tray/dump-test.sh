#!/usr/bin/env bash
# Headless end-to-end check: the real halltone-linux (tone source) + `halltone-tray --dump`.
#   Linux/tray/dump-test.sh <path to halltone-linux binary>
set -euo pipefail
bin="$1"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT
sock="$work/h.sock"

echo "--- daemon not running"
out="$("$here/halltone-tray" --dump --socket "$sock")"; echo "$out"
echo "$out" | grep -q '^icon: halltone-error-symbolic'
echo "$out" | grep -q 'Not running'

"$bin" --source tone --no-advertise --code 4242 --name "CI Rig" --port 47811 \
  --config "$work/config.json" --control-socket "$sock" >"$work/daemon.log" 2>&1 &
pid=$!
for _ in $(seq 50); do [ -S "$sock" ] && break; sleep 0.1; done

echo "--- daemon running"
out="$("$here/halltone-tray" --dump --socket "$sock")"; echo "$out"
echo "$out" | grep -q '^icon: halltone-idle-symbolic'
echo "$out" | grep -q 'Waiting for a phone'
echo "$out" | grep -q 'Pairing code: 4242'
echo "$out" | grep -q 'CI Rig'
echo "$out" | grep -q 'Game mode'
echo "$out" | grep -q 'Restart Halltone'
echo "OK"
