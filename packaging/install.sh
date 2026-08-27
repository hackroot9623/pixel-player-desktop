#!/usr/bin/env bash
# Installs the bundle into ~/.local, so no root is needed.
set -euo pipefail

APP_ID="com.theveloper.pixelplay_desktop"
BIN_NAME="pixelplay_desktop"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${PREFIX:-$HOME/.local}"
LIB_DIR="$PREFIX/lib/$APP_ID"
BIN_DIR="$PREFIX/bin"
APP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/512x512/apps"

echo "Installing PixelPlayer into $LIB_DIR"
mkdir -p "$LIB_DIR" "$BIN_DIR" "$APP_DIR" "$ICON_DIR"

# The bundle keeps its own layout: the binary needs its data/ and lib/ beside
# it, so everything is copied wholesale and only a symlink goes on PATH.
cp -r "$HERE"/. "$LIB_DIR/"
rm -f "$LIB_DIR/install.sh" "$LIB_DIR/uninstall.sh"

ln -sf "$LIB_DIR/$BIN_NAME" "$BIN_DIR/$BIN_NAME"
install -m 644 "$HERE/$APP_ID.desktop" "$APP_DIR/$APP_ID.desktop"
install -m 644 "$HERE/$APP_ID.png" "$ICON_DIR/$APP_ID.png"

# Point the launcher at the real binary rather than relying on PATH.
sed -i "s|^Exec=.*|Exec=$LIB_DIR/$BIN_NAME %U|" "$APP_DIR/$APP_ID.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" || true
fi

echo "Done. Launch it from your app menu, or run: $BIN_DIR/$BIN_NAME"
echo "Note: playback needs libmpv installed (package mpv or libmpv2)."
