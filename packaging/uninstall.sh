#!/usr/bin/env bash
# Removes what install.sh created. Leaves your settings and database alone.
set -euo pipefail

APP_ID="com.theveloper.pixelplay_desktop"
BIN_NAME="pixelplay_desktop"
PREFIX="${PREFIX:-$HOME/.local}"

rm -rf "$PREFIX/lib/$APP_ID"
rm -f "$PREFIX/bin/$BIN_NAME"
rm -f "$PREFIX/share/applications/$APP_ID.desktop"
rm -f "$PREFIX/share/icons/hicolor/512x512/apps/$APP_ID.png"

echo "Removed PixelPlayer."
echo "Your library and settings are still in:"
echo "  ~/.local/share/$APP_ID"
echo "Delete that directory too if you want a clean slate."
