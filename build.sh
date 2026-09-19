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
# eindeutige Build-Nummer (Zeitstempel), landet in den Metadaten jedes Dokuments
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Fertig: $APP"
