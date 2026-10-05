#!/bin/zsh
# Re-run under zsh if started with bash or sh.
[ -n "${ZSH_VERSION:-}" ] || exec /bin/zsh "$0" "$@"
# Builds, signs, notarizes, and staples a release DMG in one step.
#
#   scripts/release.sh                 # uses release.conf + release.local.conf
#   scripts/release.sh --no-notarize   # sign only, to check the setup without contacting Apple
#
# release.conf (committed):           VERSION, BUILD
# release.local.conf (git-ignored):   SIGN_IDENTITY, TEAM_ID, NOTARY_PROFILE
# See release.local.conf.example. Environment variables with the same names override both files.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=0 ;;
        -h|--help) sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

fail() { echo "error: $*" >&2; exit 1; }
step() { print -P "\n%B==> $*%b"; }

VERSION=${VERSION:-$(config_value VERSION)}
BUILD=${BUILD:-$(config_value BUILD)}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
SIGN_IDENTITY=${SIGN_IDENTITY:-$(config_value SIGN_IDENTITY)}
TEAM_ID=${TEAM_ID:-$(config_value TEAM_ID)}
NOTARY_PROFILE=${NOTARY_PROFILE:-$(config_value NOTARY_PROFILE)}
APP="build/Just Continue.app"

step "Checking configuration"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || fail "VERSION in release.conf must look like 1.2.3 (got '$VERSION')"
[[ "$BUILD" =~ '^[0-9]+(\.[0-9]+)*$' ]] || fail "BUILD must be numeric (got '$BUILD')"
[[ -f release.local.conf || -n "$SIGN_IDENTITY" ]] || fail "Copy release.local.conf.example to release.local.conf and fill it in"
[[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] || fail "SIGN_IDENTITY must be a 'Developer ID Application: …' identity"
[[ -n "$TEAM_ID" ]] || fail "Set TEAM_ID in release.local.conf"
[[ "$SIGN_IDENTITY" == *"($TEAM_ID)" ]] || fail "SIGN_IDENTITY doesn't belong to team $TEAM_ID"
security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\"" \
    || fail "Identity not found in keychain: $SIGN_IDENTITY (see: security find-identity -v -p codesigning)"
if (( NOTARIZE )); then
    [[ -n "$NOTARY_PROFILE" ]] || fail "Set NOTARY_PROFILE in release.local.conf"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
        || fail "Notary profile '$NOTARY_PROFILE' is missing or invalid. Create it with:
  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id \"you@example.com\" --team-id \"$TEAM_ID\""
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "warning: the working tree has uncommitted changes; they will be part of this build." >&2
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null; then
    echo "warning: tag v$VERSION already exists. Bump VERSION in release.conf for a new release." >&2
fi
if (( NOTARIZE )); then
    for existing in build/JustContinue-$VERSION-{universal,arm64,x86_64}.dmg; do
        [[ ! -e "$existing" ]] || fail "$existing already exists. Bump VERSION in release.conf, or move the old image away."
    done
fi
echo "Version $VERSION ($BUILD), team $TEAM_ID"

step "Building and signing"
unset DEBUG_MENU APP_PATH
CONFIGURATION=release VERSION="$VERSION" BUILD="$BUILD" SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh

SIGNATURE=$(codesign -dv --verbose=4 "$APP" 2>&1)
[[ "$SIGNATURE" == *"TeamIdentifier=$TEAM_ID"* ]] || fail "App isn't signed by team $TEAM_ID"
[[ "$SIGNATURE" == *"flags="*"runtime"* ]] || fail "Hardened runtime is not enabled"
[[ "$SIGNATURE" == *"Timestamp="* ]] || fail "Signature has no secure timestamp"

# Submits a file and waits; prints the notary log and fails unless Apple accepts it.
notarize() {
    local file=$1 result id stat
    result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    id=$(plutil -extract id raw -o - - <<< "$result" 2>/dev/null || true)
    stat=$(plutil -extract status raw -o - - <<< "$result" 2>/dev/null || true)
    echo "Submission $id: $stat"
    if [[ "$stat" != "Accepted" ]]; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || echo "$result" >&2
        fail "Notarization of $file was not accepted"
    fi
}

if (( NOTARIZE )); then
    step "Notarizing the app"
    ZIP="build/JustContinue-$VERSION-notarization.zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    rm -f "$ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
fi

step "Packaging the DMG"
ARCH_LABEL=universal
[[ "$(xcrun lipo -archs "$APP/Contents/MacOS/JustContinue")" == *" "* ]] || ARCH_LABEL=$(xcrun lipo -archs "$APP/Contents/MacOS/JustContinue")
if (( NOTARIZE )); then
    DMG="build/JustContinue-$VERSION-$ARCH_LABEL.dmg"
    [[ ! -e "$DMG" ]] || fail "$DMG already exists. Bump VERSION in release.conf, or move the old image away."
else
    DMG="build/JustContinue-$VERSION-$ARCH_LABEL-unnotarized.dmg"
    rm -f "$DMG"
fi
SIGN_IDENTITY="$SIGN_IDENTITY" scripts/package-dmg.sh "$APP" "$DMG"

if (( NOTARIZE )); then
    step "Notarizing the DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi

step "Done"
shasum -a 256 "$DMG"
if (( NOTARIZE )); then
    cat <<EOF
Release ready: $DMG
Test it on a clean Mac, then publish:
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION "$DMG" --title "Just Continue $VERSION"
EOF
else
    echo "Signed but NOT notarized (--no-notarize): $DMG — don't publish this image."
fi
