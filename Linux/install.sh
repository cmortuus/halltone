#!/usr/bin/env bash
# Builds halltone-linux, installs it to ~/.local/bin and sets it up as a systemd *user* service
# (halltone.service) so it runs at login. Also installs halltone-tray, the top-bar icon and menu
# (autostarts at login). Ubuntu 22.04+ / 24.04.
#
#   Linux/install.sh              build, install, enable and start the service
#   Linux/install.sh --no-service build and install the binary only
#   Linux/install.sh --yes        don't ask before apt-installing missing packages
#   Linux/install.sh --uninstall  stop and remove the service and the binary (keeps your config)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
config="${XDG_CONFIG_HOME:-$HOME/.config}/halltone/config.json"

assume_yes=0; with_service=1; uninstall=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) assume_yes=1 ;;
    --no-service) with_service=0 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

have_systemd_user() { command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }

if [ "$uninstall" = 1 ]; then
  if have_systemd_user; then
    systemctl --user disable --now halltone.service 2>/dev/null || true
    rm -f "$unit_dir/halltone.service"
    systemctl --user daemon-reload || true
  fi
  rm -f "$bin_dir/halltone-linux" "$bin_dir/halltone-tray" "$autostart_dir/halltone-tray.desktop" "$data_dir/applications/halltone-tray.desktop"
  rm -f "$data_dir"/icons/hicolor/scalable/status/halltone-{idle,streaming,error}-symbolic.svg
  pkill -u "$(id -u)" -f "$bin_dir/halltone-tray" 2>/dev/null || true
  echo "Removed halltone-linux and its service. Your config ($config) is kept."
  exit 0
fi

# 1. Packages. libpulse-dev (+ pkg-config) are needed to build; avahi-utils lets the phone find
#    this PC by name (without it you add the PC by IP with + in the phone app); pulseaudio-utils
#    (pactl) lets capture follow a change of default output.
missing_required=(); missing_optional=()
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
for p in libpulse-dev pkg-config; do pkg_installed "$p" || missing_required+=("$p"); done
for p in avahi-utils pulseaudio-utils python3-gi gir1.2-ayatanaappindicator3-0.1; do pkg_installed "$p" || missing_optional+=("$p"); done

if [ ${#missing_required[@]} -gt 0 ] || [ ${#missing_optional[@]} -gt 0 ]; then
  echo "Halltone needs these Ubuntu packages and they are not installed:"
  [ ${#missing_required[@]} -gt 0 ] && echo "  required (to build):       ${missing_required[*]}"
  [ ${#missing_optional[@]} -gt 0 ] && echo "  recommended (discovery, top-bar icon): ${missing_optional[*]}"
  answer=n
  if [ "$assume_yes" = 1 ]; then answer=y; else
    read -r -p "Install them now with 'sudo apt-get install'? [y/N] " answer || true
  fi
  if [[ "$answer" =~ ^[Yy] ]]; then
    sudo apt-get update
    sudo apt-get install -y "${missing_required[@]}" "${missing_optional[@]}"
  elif [ ${#missing_required[@]} -gt 0 ]; then
    echo "Can't build without: ${missing_required[*]}. Install them with:" >&2
    echo "  sudo apt-get install ${missing_required[*]} ${missing_optional[*]}" >&2
    exit 1
  else
    echo "Continuing without: ${missing_optional[*]} (the phone will need the PC added by IP with +)."
  fi
fi

# 2. Swift toolchain.
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Install a 6.x toolchain (swiftly: https://www.swift.org/install/linux/)," >&2
  echo "open a new shell so 'swift' is on PATH, then run this script again." >&2
  exit 1
fi
swift --version | head -1

# 3. Build and install.
echo "Building halltone-linux (release; the first build compiles libopus and takes a few minutes)..."
(cd "$here/halltone-linux" && swift build -c release)
mkdir -p "$bin_dir"
install -m 755 "$here/halltone-linux/.build/release/halltone-linux" "$bin_dir/halltone-linux"
echo "Installed $bin_dir/halltone-linux"
case ":$PATH:" in *":$bin_dir:"*) ;; *) echo "Note: $bin_dir isn't on your PATH." ;; esac

# 4. Service.
if [ "$with_service" = 1 ]; then
  if have_systemd_user; then
    mkdir -p "$unit_dir"
    install -m 644 "$here/halltone.service" "$unit_dir/halltone.service"
    systemctl --user daemon-reload
    systemctl --user enable --now halltone.service
    sleep 2
    systemctl --user --no-pager --lines=0 status halltone.service || true
    echo "Service enabled: halltone runs at login. Logs: journalctl --user -u halltone -f"
  else
    echo "No systemd user session here, so no service was installed. Run halltone-linux by hand."
  fi
fi

# 4b. The top-bar icon (halltone-tray): script, symbolic icons, launcher, autostart at login.
install -m 755 "$here/tray/halltone-tray" "$bin_dir/halltone-tray"
mkdir -p "$data_dir/icons/hicolor/scalable/status" "$data_dir/applications" "$autostart_dir"
install -m 644 "$here"/tray/icons/halltone-*-symbolic.svg "$data_dir/icons/hicolor/scalable/status/"
sed "s|^Exec=.*|Exec=$bin_dir/halltone-tray|" "$here/tray/halltone-tray.desktop" > "$data_dir/applications/halltone-tray.desktop"
sed "s|^Exec=.*|Exec=$bin_dir/halltone-tray|" "$here/tray/halltone-tray-autostart.desktop" > "$autostart_dir/halltone-tray.desktop"
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f "$data_dir/icons/hicolor" 2>/dev/null || true
echo "Installed $bin_dir/halltone-tray (top-bar icon; starts at login; start it now with: halltone-tray &)"
echo "On Ubuntu's GNOME the icon needs the AppIndicator extension (ubuntu-appindicators@ubuntu.com, enabled by default)."

# 5. The pairing code the phone asks for.
if [ -f "$config" ]; then
  code="$(sed -n 's/.*"pairingCode"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]\{4\}\).*/\1/p' "$config" | head -1)"
  [ -n "$code" ] && echo "Pairing code: $code   (stored in $config)"
fi
echo "Open Halltone on the iPhone: this PC should appear within a few seconds; enter the pairing code."
