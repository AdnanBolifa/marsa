#!/bin/bash
# Builds the Mac App Store edition: the same app, signed for the store and
# confined to Apple's sandbox, packaged as dist/Marsa-appstore.pkg ready to
# upload. See docs/app-store.md for the one-time setup this expects.
#
#   tool/build_appstore.sh path/to/Marsa_AppStore.provisionprofile
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-}"
[ -f "$PROFILE" ] || { echo "Usage: tool/build_appstore.sh path/to/profile.provisionprofile"; exit 1; }

# Read the team and app this profile is for, so nothing is typed twice.
PLIST="$(mktemp)"; trap 'rm -f "$PLIST" "$PLIST.ent"' EXIT
security cms -D -i "$PROFILE" > "$PLIST"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PLIST")"
TEAM="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PLIST")"
BUNDLE="$(sed -n 's/^PRODUCT_BUNDLE_IDENTIFIER = //p' macos/Runner/Configs/AppInfo.xcconfig)"
[ "$APP_ID" = "$TEAM.$BUNDLE" ] || {
  echo "That profile is for $APP_ID, but the app is $TEAM.$BUNDLE."; exit 1; }

identity() { security find-identity -v | grep -o "\"$1: [^\"]*($TEAM)\"" | head -1 | tr -d '"' || true; }
APP_CERT="$(identity 'Apple Distribution')"
[ -n "$APP_CERT" ] || APP_CERT="$(identity '3rd Party Mac Developer Application')"
PKG_CERT="$(identity '3rd Party Mac Developer Installer')"
[ -n "$APP_CERT" ] || { echo "No 'Apple Distribution' certificate for team $TEAM in the keychain."; exit 1; }
[ -n "$PKG_CERT" ] || { echo "No 'Mac Installer Distribution' certificate for team $TEAM in the keychain."; exit 1; }
echo "Signing as: $APP_CERT"

DEFINES=(); [ -f cloud_keys.json ] && DEFINES=(--dart-define-from-file=cloud_keys.json)
flutter build macos --release ${DEFINES[@]+"${DEFINES[@]}"}

OUT=dist/appstore; rm -rf "$OUT"; mkdir -p "$OUT"
APP="$OUT/Marsa.app"
ditto build/macos/Build/Products/Release/Marsa.app "$APP"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# A downloaded profile carries the "from the internet" mark, which the store
# refuses to find inside an app.
xattr -cr "$APP"

# The sandbox entitlements, plus who the app belongs to.
cp macos/Runner/AppStore.entitlements "$PLIST.ent"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" \
  -c "Add :com.apple.developer.team-identifier string $TEAM" "$PLIST.ent"

# Inside out: the frameworks first, the app that holds them last.
find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  xargs -0 -n1 codesign --force --timestamp --sign "$APP_CERT"
codesign --force --timestamp --options runtime --entitlements "$PLIST.ent" --sign "$APP_CERT" "$APP"
codesign --verify --deep --strict "$APP"

PKG=dist/Marsa-appstore.pkg
productbuild --component "$APP" /Applications --sign "$PKG_CERT" "$PKG"
pkgutil --check-signature "$PKG" | head -3

echo
echo "Built $PKG"
echo "Upload it with the Transporter app (free on the Mac App Store): drag the"
echo "file in and press Deliver. Or from here:"
echo "  xcrun altool --upload-app -t macos -f $PKG -u YOUR_APPLE_ID -p YOUR_APP_SPECIFIC_PASSWORD"
