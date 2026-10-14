#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$(cd ../.. && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'macOS packaging requires a macOS build host.' >&2
  exit 1
fi
if [[ ! -f secrets/keys.enc.json ]]; then
  echo 'secrets/keys.enc.json is missing. Run: python encrypt_secrets.py --bigmodel <key> --mimo <key>' >&2
  exit 1
fi
(cd "$root/Desktop" && npm ci && npm run build)
python3 -m pip install -r requirements-desktop.txt -r requirements-grammar.txt pyinstaller pillow cryptography
python3 -c "from PIL import Image; Image.open('../../Desktop/public/app-icon.png').save('../../Desktop/public/app-icon.icns')"
python3 -m PyInstaller LingoClass.spec --distpath "$root/Releases/macOS" --workpath "$root/Build/macos-package" --noconfirm
app="$root/Releases/macOS/LingoClass.app"
test -d "$app/Contents/MacOS"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
# No live credential may appear in the bundle outside the sealed document.
if grep -rqE 'sk-[A-Za-z0-9]{16,}' "$app/Contents/MacOS" --include='*.json' --include='*.py' 2>/dev/null; then
  echo 'A plaintext API key was found in LingoClass.app' >&2
  exit 1
fi
# Installer copies the complete self-contained bundle to Applications.
pkgbuild --component "$app" --install-location /Applications --identifier com.lingoclass.desktop --version 2026.10.14 "$root/Releases/macOS/LingoClass-Setup.pkg"
