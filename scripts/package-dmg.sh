#!/bin/zsh
# Package an existing app without rebuilding or modifying it.
#   scripts/package-dmg.sh [app-path] [output.dmg]
# Set SIGN_IDENTITY to a Developer ID Application identity to sign the disk image.
# Notarize and staple the app before packaging, then notarize and staple the DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:-"build/Just Continue.app"}
[[ -d "$APP" ]] || { echo "App not found: $APP" >&2; exit 1; }
codesign --verify --strict "$APP"
RELEASE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH_LIST=$(xcrun lipo -archs "$APP/Contents/MacOS/JustContinue")
case "$ARCH_LIST" in
    *arm64*x86_64*|*x86_64*arm64*) ARCH_LABEL=universal ;;
    arm64|x86_64) ARCH_LABEL=$ARCH_LIST ;;
    *) echo "Unexpected architectures: $ARCH_LIST" >&2; exit 1 ;;
esac
DMG=${2:-"build/JustContinue-${RELEASE_VERSION}-${ARCH_LABEL}.dmg"}
[[ ! -e "$DMG" ]] || { echo "Already exists: $DMG. Choose another output path or move the old image." >&2; exit 1; }

STAGING=$(mktemp -d "${TMPDIR:-/tmp/}just-continue-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
# Explicitly copy only the app, never other files in build/.
ditto "$APP" "$STAGING/Just Continue.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Just Continue" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --strict "$DMG"
fi
hdiutil verify "$DMG"
echo "Packaged $DMG. Notarize and staple this image before publishing."
