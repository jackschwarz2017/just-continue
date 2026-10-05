#!/bin/zsh
# Re-run under zsh if started with bash or sh.
[ -n "${ZSH_VERSION:-}" ] || exec /bin/zsh "$0" "$@"
# Builds build/Just Continue.app from the Swift package.
# VERSION and BUILD come from release.conf, SIGN_IDENTITY from release.local.conf (if present);
# environment variables override both.
#
#   scripts/build-app.sh                 # universal (Apple Silicon + Intel), ad-hoc signed
#   CONFIGURATION=debug APP_PATH="build/Just Continue Debug.app" scripts/build-app.sh
#   ARCHS=x86_64 scripts/build-app.sh    # Intel only
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   DEBUG_MENU=1 scripts/build-app.sh   # include the hidden Debug menu (hold ⌥ when opening the menu)
#
# Note: with ad-hoc signing, macOS ties permissions (Automation) to the exact binary,
# so you may be asked again after each rebuild. Use a stable identity to avoid that.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

BUNDLE_ID=${BUNDLE_ID:-dev.justcontinue.JustContinue}
VERSION=${VERSION:-$(config_value VERSION)}
BUILD=${BUILD:-$(config_value BUILD)}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
[[ -n "$VERSION" ]] || { echo "Set VERSION in release.conf" >&2; exit 1; }
SIGN_IDENTITY=${SIGN_IDENTITY:-$(config_value SIGN_IDENTITY -)}
ARCHS=${ARCHS:-"arm64 x86_64"}
CONFIGURATION=${CONFIGURATION:-release}
APP=${APP_PATH:-"build/Just Continue.app"}
[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || { echo "Invalid CONFIGURATION" >&2; exit 1; }

FLAGS=()
[[ -n "${DEBUG_MENU:-}" ]] && FLAGS=(-Xswiftc -DDEBUG_MENU)
BINS=()
for BUILD_ARCH in ${=ARCHS}; do
    case "$BUILD_ARCH" in
        arm64|x86_64) ;;
        *) echo "Unsupported architecture: $BUILD_ARCH" >&2; exit 1 ;;
    esac
    BUILD_FLAGS=(--scratch-path ".build/app-$BUILD_ARCH" --triple "$BUILD_ARCH-apple-macosx14.0")
    swift build -c "$CONFIGURATION" --product JustContinue "${BUILD_FLAGS[@]}" "${FLAGS[@]}"
    BINS+=("$(swift build -c "$CONFIGURATION" --show-bin-path "${BUILD_FLAGS[@]}" "${FLAGS[@]}")/JustContinue")
done
[[ ${#BINS[@]} -gt 0 ]] || { echo "ARCHS must include arm64 or x86_64" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ${#BINS[@]} -eq 1 ]]; then
    cp "${BINS[1]}" "$APP/Contents/MacOS/JustContinue"
else
    xcrun lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/JustContinue"
fi
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD)/$BUILD/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

# App icon: compile the Icon Composer file into Assets.car (macOS 26) and AppIcon.icns (older macOS).
ICON_OUT="$(mktemp -d)"
xcrun actool --compile "$ICON_OUT" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$ICON_OUT/partial.plist" \
    Resources/AppIcon/AppIcon.icon > /dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$ICON_OUT"

TIMESTAMP_FLAG=--timestamp
[[ "$SIGN_IDENTITY" == "-" ]] && TIMESTAMP_FLAG=--timestamp=none
codesign --force --options runtime "$TIMESTAMP_FLAG" \
    --entitlements Resources/JustContinue.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
xcrun lipo -archs "$APP/Contents/MacOS/JustContinue"

# macOS caches app icons per path; refresh it so a rebuilt app doesn't keep showing an old icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "Built $APP ($BUNDLE_ID $VERSION ($BUILD), signed: $SIGN_IDENTITY)"
