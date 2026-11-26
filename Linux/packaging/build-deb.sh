#!/usr/bin/env bash
# Builds halltone-linux_<version>_<arch>.deb (static Swift stdlib: the target needs no Swift).
#
#   Linux/packaging/build-deb.sh <version> [arch]   arch defaults to `dpkg --print-architecture`
#
# Output: Linux/packaging/out/halltone-linux_<version>_<arch>.deb (name is a contract with the apt
# repo server that imports GitHub Releases). Must run on the target arch (no cross-compiling).
# Needs: swift 6.x, libpulse-dev, pkg-config, dpkg-dev (dpkg-shlibdeps), binutils.
set -euo pipefail

[ $# -ge 1 ] || { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
version="$1"
arch="${2:-$(dpkg --print-architecture)}"
[ "$arch" = "$(dpkg --print-architecture)" ] || { echo "arch $arch != host $(dpkg --print-architecture); build on that arch" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$here/out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkg="$work/pkg"

echo "Building halltone-linux (release, static Swift stdlib)..."
(cd "$repo/Linux/halltone-linux" && swift build -c release --static-swift-stdlib)
bin="$repo/Linux/halltone-linux/.build/release/halltone-linux"

mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib/systemd/user" "$pkg/usr/share/doc/halltone-linux"
install -m 755 "$bin" "$pkg/usr/bin/halltone-linux"
strip --strip-unneeded "$pkg/usr/bin/halltone-linux"

sed 's|^ExecStart=.*|ExecStart=/usr/bin/halltone-linux|' "$repo/Linux/halltone.service" \
  > "$pkg/usr/lib/systemd/user/halltone.service"
grep -q '^ExecStart=/usr/bin/halltone-linux$' "$pkg/usr/lib/systemd/user/halltone.service"
chmod 644 "$pkg/usr/lib/systemd/user/halltone.service"

# Copyright: project license (GPL-3+) plus vendored libopus and libfvad.
{
  echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
  echo "Upstream-Name: halltone"
  echo "Source: https://github.com/cmortuus/halltone"
  echo
  echo "Files: *"
  echo "Copyright: 2026 the Halltone authors"
  echo "License: GPL-3+"
  echo " On Debian systems the full text of the GNU General Public License version 3"
  echo " is in /usr/share/common-licenses/GPL-3. It is also reproduced below."
  echo
  echo "Files: Packages/HalltoneCore/Sources/COpus/*"
  echo "Copyright: Xiph.Org Foundation, Skype Limited, and other libopus contributors"
  echo "License: BSD-3-Clause (libopus)"
  echo
  echo "Files: Packages/HalltoneDialog/Sources/CFVAD/*"
  echo "Copyright: The WebRTC project authors, libfvad contributors"
  echo "License: BSD-3-Clause (libfvad)"
  echo
  echo "=== Halltone: GNU General Public License ==="
  cat "$repo/LICENSE"
  echo
  echo "=== libopus license ==="
  cat "$repo/Packages/HalltoneCore/Sources/COpus/opus/COPYING"
  echo
  echo "=== libfvad (WebRTC VAD) license ==="
  cat "$repo/Packages/HalltoneDialog/Sources/CFVAD/LICENSE"
} > "$pkg/usr/share/doc/halltone-linux/copyright"
chmod 644 "$pkg/usr/share/doc/halltone-linux/copyright"

# Depends from the binary's shared-library needs (libc6, libpulse0, ...).
mkdir -p "$work/shl/debian"
printf 'Source: halltone-linux\n\nPackage: halltone-linux\nArchitecture: any\n' > "$work/shl/debian/control"
depends="$(cd "$work/shl" && dpkg-shlibdeps -O -e"$pkg/usr/bin/halltone-linux" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"
[ -n "$depends" ] || { echo "dpkg-shlibdeps produced no Depends" >&2; exit 1; }
echo "Depends: $depends"

size_kb="$(du -sk --exclude=DEBIAN "$pkg" | cut -f1)"
cat > "$pkg/DEBIAN/control" <<CTL
Package: halltone-linux
Version: $version
Section: sound
Priority: optional
Architecture: $arch
Maintainer: cmortuus <cmortuus@users.noreply.github.com>
Installed-Size: $size_kb
Depends: $depends
Recommends: avahi-utils, pulseaudio-utils
Homepage: https://github.com/cmortuus/halltone
Description: Stream this PC's audio to the Halltone iPhone app
 halltone-linux captures the default PulseAudio/PipeWire output and streams it
 over the local network to the Halltone app on an iPhone (low-latency PCM or
 Opus), advertises itself with Avahi, and can pause the PC's media player while
 dialog is detected. Run as a systemd user service.
CTL

cat > "$pkg/DEBIAN/postinst" <<'SH'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  if [ -n "$2" ]; then
    echo "halltone-linux upgraded. Running users: systemctl --user restart halltone"
  else
    cat <<MSG
halltone-linux installed. The service is not enabled automatically. As your own user, run:
  systemctl --user daemon-reload && systemctl --user enable --now halltone
Then find the pairing code with:
  journalctl --user -u halltone -n 20      (or "pairingCode" in ~/.config/halltone/config.json)
MSG
  fi
fi
exit 0
SH
cat > "$pkg/DEBIAN/prerm" <<'SH'
#!/bin/sh
set -e
if [ "$1" = "remove" ]; then
  echo "Removing halltone-linux. Users who enabled it: systemctl --user disable --now halltone"
fi
exit 0
SH
chmod 755 "$pkg/DEBIAN/postinst" "$pkg/DEBIAN/prerm"

mkdir -p "$out"
deb="$out/halltone-linux_${version}_${arch}.deb"
dpkg-deb --build --root-owner-group "$pkg" "$deb"
echo "Built $deb"
dpkg-deb -I "$deb"
dpkg-deb -c "$deb"
