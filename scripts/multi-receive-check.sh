#!/bin/zsh
# Multi-source check without a phone: two tone senders on different ports (440 Hz normal, 880 Hz in
# Game mode = 2.5 ms frames), received at once through the phone's SourceManager + mix bus into one
# WAV. Checks both tones are in the mix, then that --volumes scales one and --mute-last silences one.
set -uo pipefail
cd "$(dirname "$0")/../Tools/halltone-cli"
swift build -c release 2>&1 | tail -1
CLI=.build/release/halltone-cli
dir=$(mktemp -d)
trap 'pkill -f "halltone-cli send" 2>/dev/null; rm -rf "$dir"' EXIT
fail=0

run() { # name, receive args...
  local name=$1; shift
  pkill -f "halltone-cli send" 2>/dev/null; sleep 1
  $CLI send --source tone --freq 440 --port 47810 --no-bonjour --seconds 12 >/dev/null 2>&1 &
  $CLI send --source tone --freq 880 --port 47811 --no-bonjour --seconds 12 --game >/dev/null 2>&1 &
  sleep 1.5
  $CLI receive --multi 127.0.0.1:47810 127.0.0.1:47811 --seconds 5 --wav "$dir/$name.wav" "$@" >"$dir/$name.log" 2>&1
  $CLI analyze "$dir/$name.wav" --tones 440,880 | grep '^tone' >"$dir/$name.tones"
}
amp() { sed -n "s/^tone $2 Hz: amplitude //p" "$dir/$1.tones"; }
check() { # description, name, freq, min, max
  local a=$(amp $2 $3)
  if awk -v a="$a" -v lo=$4 -v hi=$5 'BEGIN{exit !(a>=lo && a<=hi)}'; then echo "ok   $1 ($3 Hz = $a)"; else echo "FAIL $1 ($3 Hz = ${a:-none}, want $4...$5)"; grep -v '^\[recv.*pkt/s' "$dir/$2.log" | tail -5; fail=1; fi
}

run both
check "both sources in the mix" both 440 0.25 0.35
check "both sources in the mix (Game source: fades allowed)" both 880 0.1 0.35
grep -q "mode game" "$dir/both.log" && grep -q "mode auto" "$dir/both.log" \
  && echo "ok   default latency: Auto for 5 ms frames, Game for 2.5 ms frames" || { echo "FAIL default latency modes"; fail=1; }
# Volume and mute runs use --mode stable for both: the 15 ms Game buffer fades on a busy machine, by design.
run vol --mode stable --volumes 1,0.5
check "volume 1" vol 440 0.25 0.35
check "volume 0.5 (amplitude x 0.25)" vol 880 0.06 0.09
run mute --mode stable --mute-last
check "unmuted source" mute 440 0.25 0.35
check "muted source" mute 880 0 0.005
exit $fail
