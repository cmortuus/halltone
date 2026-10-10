#!/bin/zsh
# Reproduces Wi-Fi power-save bursts on loopback and reports how the receiver copes.
# Usage: scripts/burst-test.sh [burst-ms] [every-ms] [seconds]
set -uo pipefail
cd "$(dirname "$0")/.."
BURST=${1:-250}; EVERY=${2:-1500}; SECS=${3:-30}
CLI=Tools/halltone-cli/.build/release/halltone-cli
OUT=$(mktemp -d)
PORT=$((47900 + RANDOM % 50))
$CLI send --source tone --codec opus --port $PORT --no-bonjour --seconds $((SECS + 4)) --sim-burst $BURST --sim-burst-every $EVERY >/dev/null 2>&1 &
sleep 1
HALLTONE_CALLBACK_FRAMES=256 $CLI receive 127.0.0.1:$PORT --wav "$OUT/rx.wav" --seconds $SECS 2>&1 | grep "pkt/s" | tail -1
python3 -I - "$OUT/rx.wav" <<'PY'
import sys, wave, struct
w=wave.open(sys.argv[1]); n=w.getnframes(); s=struct.unpack("<%dh"%(n*2), w.readframes(n))[0::2]
win=96; run=0; gaps=[]
for i in range(48000*2, n-win, win):
    if max(abs(v) for v in s[i:i+win]) < 300: run+=1
    else:
        if run: gaps.append(run*2)
        run=0
tot=sum(gaps)
print(f"silent gaps after 2 s: {len(gaps)}, total {tot} ms ({100*tot/((n-96000)/48):.1f}% of the time), longest {max(gaps) if gaps else 0} ms")
PY
wait
rm -rf -- "${OUT:?}"
