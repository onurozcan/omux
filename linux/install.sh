#!/bin/sh
# Installs omux for the current user (no root needed):
#   ./install.sh [path/to/omux]     binary from a release or `cargo build --release`
#   ./install.sh --uninstall
set -eu
cd "$(dirname "$0")"
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin/omux"
APPS="$PREFIX/share/applications"
ICONS="$PREFIX/share/icons/hicolor/scalable/apps"
META="$PREFIX/share/metainfo"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$BIN" "$APPS/net.pf1.omux.desktop" "$ICONS/net.pf1.omux.svg" "$META/net.pf1.omux.metainfo.xml"
  update-desktop-database "$APPS" 2>/dev/null || true
  echo "omux removed from $PREFIX"
  exit 0
fi

SOURCE="${1:-target/release/omux}"
[ -x "$SOURCE" ] || { echo "No omux binary at $SOURCE" >&2; exit 1; }

# Ask the dynamic linker what the binary itself still lacks.
missing=$(ldd "$SOURCE" 2>/dev/null | awk '/not found/ {print $1}' | tr '\n' ' ')
if [ -n "$missing" ]; then
  echo "Missing libraries: $missing" >&2
  echo "On Ubuntu/Debian: sudo apt install libgtk-4-1 libadwaita-1-0 libvte-2.91-gtk4-0 libwebkitgtk-6.0-4" >&2
fi

install -Dm755 "$SOURCE" "$BIN"
install -Dm644 data/net.pf1.omux.desktop "$APPS/net.pf1.omux.desktop"
install -Dm644 data/net.pf1.omux.svg "$ICONS/net.pf1.omux.svg"
install -Dm644 data/net.pf1.omux.metainfo.xml "$META/net.pf1.omux.metainfo.xml"
update-desktop-database "$APPS" 2>/dev/null || true
gtk-update-icon-cache -q "$PREFIX/share/icons/hicolor" 2>/dev/null || true
echo "omux installed to $BIN"
case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) echo "Add $PREFIX/bin to PATH to run omux from a terminal." ;; esac
