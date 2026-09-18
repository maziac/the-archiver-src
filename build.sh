#!/bin/bash
# Baut ScanArchiv.app (Release) nach build/ScanArchiv.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/ScanArchiv.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ScanArchiv "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Fertig: $APP"
