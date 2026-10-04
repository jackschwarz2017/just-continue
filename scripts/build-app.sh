#!/bin/zsh
# Builds build/Just Continue.app from the Swift package.
#
#   scripts/build-app.sh                 # ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   DEBUG_MENU=1 scripts/build-app.sh   # include the hidden Debug menu (hold ⌥ when opening the menu)
#
# Note: with ad-hoc signing, macOS ties permissions (Automation) to the exact binary,
# so you may be asked again after each rebuild. Use a stable identity to avoid that.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=${BUNDLE_ID:-dev.justcontinue.JustContinue}
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
SIGN_IDENTITY=${SIGN_IDENTITY:--}

FLAGS=()
[[ -n "${DEBUG_MENU:-}" ]] && FLAGS=(-Xswiftc -DDEBUG_MENU)
swift build -c release --product JustContinue "${FLAGS[@]}"
BIN="$(swift build -c release --show-bin-path "${FLAGS[@]}")/JustContinue"

APP="build/Just Continue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JustContinue"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD)/$BUILD/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

# App icon: compile the Icon Composer file into Assets.car (macOS 26) and AppIcon.icns (older macOS).
ICON_OUT="$(mktemp -d)"
xcrun actool --compile "$ICON_OUT" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$ICON_OUT/partial.plist" \
    Resources/AppIcon/AppIcon.icon > /dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$ICON_OUT"

codesign --force --options runtime --timestamp=none \
    --entitlements Resources/JustContinue.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

# macOS caches app icons per path; refresh it so a rebuilt app doesn't keep showing an old icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "Built $APP ($BUNDLE_ID $VERSION ($BUILD), signed: $SIGN_IDENTITY)"
