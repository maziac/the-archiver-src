#!/bin/bash
# Baut The Archiver für den Mac App Store: build/AppStore/The Archiver.app (+ TheArchiver.pkg)
#
#   ./build-appstore.sh            → ad hoc signiert, mit Sandbox (zum Testen, ohne Zertifikate)
#   SIGN_IDENTITY="Apple Distribution: …" INSTALLER_IDENTITY="3rd Party Mac Developer Installer: …" \
#   PROFILE=path/to.provisionprofile ./build-appstore.sh   → signiertes .pkg zum Hochladen
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=${ARCHS:-"arm64 x86_64"}
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}"
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/ScanArchiv

OUT=build/AppStore
APP="$OUT/The Archiver.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# eindeutige, steigende Build-Nummer (Zeitstempel)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign - --entitlements Resources/ScanArchiv.entitlements "$APP"
    echo "Fertig (ad hoc, Sandbox): $APP"
    exit 0
fi

: "${PROFILE:?PROFILE (Provisioning-Profil Mac App Store) fehlt}"
: "${INSTALLER_IDENTITY:?INSTALLER_IDENTITY fehlt}"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# Team- und App-ID aus dem Profil in die Entitlements übernehmen
ENT=$OUT/entitlements.plist
cp Resources/ScanArchiv.entitlements "$ENT"
security cms -D -i "$PROFILE" > "$OUT/profile.plist"
APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$OUT/profile.plist")
TEAM=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$OUT/profile.plist")
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" \
    -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENT"

codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ENT" "$APP"
codesign --verify --strict --verbose=2 "$APP"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$OUT/TheArchiver.pkg"
echo "Fertig: $OUT/TheArchiver.pkg"
