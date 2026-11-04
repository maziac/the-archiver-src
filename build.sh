#!/bin/bash
# Baut Archiver.app (Release) nach build/Archiver.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Archiver.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Archiver "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# eindeutige Build-Nummer (Zeitstempel), landet in den Metadaten jedes Dokuments
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Fertig: $APP"
