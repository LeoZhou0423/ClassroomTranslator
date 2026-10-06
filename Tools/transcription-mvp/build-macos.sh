#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$(cd ../.. && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'macOS packaging requires a macOS build host.' >&2
  exit 1
fi
(cd "$root/Desktop" && npm ci && npm run build)
python3 -m pip install -r requirements-desktop.txt -r requirements-grammar.txt pyinstaller pillow
python3 -c "from PIL import Image; Image.open('../../Desktop/public/app-icon.png').save('../../Desktop/public/app-icon.icns')"
python3 -m PyInstaller LingoClass.spec --distpath "$root/Releases/macOS" --workpath "$root/Build/macos-package" --noconfirm
app="$root/Releases/macOS/LingoClass.app"
test -d "$app/Contents/MacOS"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
# Installer copies the complete self-contained bundle to Applications.
pkgbuild --component "$app" --install-location /Applications --identifier com.lingoclass.desktop --version 2026.10.06 "$root/Releases/macOS/LingoClass-Setup.pkg"
