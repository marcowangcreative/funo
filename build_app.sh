#!/bin/bash
# QuickCull beta packaging: universal build → .app bundle → Developer ID
# signing → notarization → stapled DMG ready to send to testers.
#
# ONE-TIME SETUP (before first run):
#   xcrun notarytool store-credentials quickcull-notary \
#       --apple-id "YOUR_APPLE_ID@EMAIL" --team-id YOUR_TEAM_ID
#   (generate an app-specific password at appleid.apple.com when prompted)
#
# Then each beta build is just:  ./build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

# Brand: "f/uno" everywhere the USER sees it; "Funo" everywhere the
# FILESYSTEM sees it (a literal / in bundle or volume names breaks paths).
PRODUCT_NAME="QuickCull"                 # swift build product (internal)
APP_NAME="Funo"                          # .app bundle + executable name
DISPLAY_NAME="Funo"   # Plain ASCII everywhere the SYSTEM sees a name (Finder,
                   # Dock, Sparkle download dirs — a "/" here broke every OTA
                   # download). The f/uno brand lives in UI copy and the site.
VERSION="${VERSION:-0.9.0}"
BUNDLE_ID="${BUNDLE_ID:-com.funophoto.funo}"
NOTARY_PROFILE="${NOTARY_PROFILE:-quickcull-notary}"

# Universal (arm64 + x86_64) builds need FULL Xcode's build system; with
# only the Command Line Tools selected, fall back to the Mac's native arch.
# (Native-only is fine for an Apple Silicon tester circle; install Xcode and
# `sudo xcode-select -s /Applications/Xcode.app` to ship universal.)
if [[ "$(xcode-select -p 2>/dev/null)" == *"Xcode.app"* ]]; then
  echo "▸ Building universal release binary (arm64 + x86_64)…"
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/$PRODUCT_NAME"
else
  echo "▸ Command Line Tools only — building native arch ($(uname -m)) release…"
  echo "  (for a universal beta: install Xcode, then sudo xcode-select -s /Applications/Xcode.app)"
  swift build -c release
  BIN=".build/release/$PRODUCT_NAME"
fi
[ -f "$BIN" ] || { echo "build product not found"; exit 1; }

echo "▸ Assembling $APP_NAME.app…"
DIST="dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$DIST"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SPM puts target resources (banner.png) in a separate bundle NEXT TO the
# binary — Bundle.module fatalErrors at launch if it isn't shipped. Copy it
# into Contents/Resources, where the generated accessor also looks.
RESBUNDLE="$(dirname "$BIN")/QuickCull_QuickCull.bundle"
if [ -d "$RESBUNDLE" ]; then
  cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
  echo "  bundled resources: QuickCull_QuickCull.bundle"
else
  echo "ERROR: resource bundle not found at $RESBUNDLE — app would crash at launch"; exit 1
fi

# Sparkle.framework rides in Contents/Frameworks; the binary finds it via rpath.
FW_SRC=$(find .build -type d -name "Sparkle.framework" -path "*artifacts*" 2>/dev/null | head -1)
if [ -n "$FW_SRC" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$FW_SRC" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  echo "  embedded: Sparkle.framework"
else
  echo "WARNING: Sparkle.framework not found in .build — updates disabled in this build"
fi

# Sparkle EdDSA public key. Pairs with the private key in the login Keychain
# (from `generate_keys`). Public — it ships in every build's Info.plist.
# Override per-build with  SPARKLE_ED_KEY="..." ./build_app.sh  if you rotate it.
SPARKLE_ED_KEY="${SPARKLE_ED_KEY:-tZKIxxv+AEBnNuXJHgP/BlG/7rw2lo+/T78fTduDj68=}"
SPARKLE_KEY_ENTRY=""
if [ -n "${SPARKLE_ED_KEY:-}" ]; then
  SPARKLE_KEY_ENTRY="<key>SUPublicEDKey</key><string>$SPARKLE_ED_KEY</string>"
else
  echo "NOTE: SPARKLE_ED_KEY not set — updates will be signature-less (dev only)."
fi

# Optional icon: put AppIcon.icns next to this script to include it.
ICON_KEY=""
if [ -f "AppIcon.icns" ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>SUFeedURL</key><string>https://www.funo.photo/updates/appcast.xml</string>
    <key>SUEnableAutomaticChecks</key><true/>
    $SPARKLE_KEY_ENTRY
    $ICON_KEY
</dict>
</plist>
PLIST

echo "▸ Signing with Developer ID…"
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' certificate found in keychain."; echo "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"; exit 1; }
echo "  identity: $IDENTITY"
# Sparkle's nested helpers must be signed before the framework, the
# framework before the app (codesign does not recurse).
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  codesign -f -o runtime --timestamp --preserve-metadata=entitlements -s "$IDENTITY" "$FW/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
  codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
  codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/Versions/B/Autoupdate" 2>/dev/null || true
  codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/Versions/B/Updater.app" 2>/dev/null || true
  codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW"
fi
# Normalize permissions BEFORE signing: assets written by tools can arrive
# 0600, and generate_appcast (rightly) complains about non-world-readable
# resources inside the bundle.
chmod -R u+rwX,go+rX,go-w "$APP"

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Building DMG…"
STAGE="$DIST/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "funo" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "▸ Notarizing (this waits on Apple — usually 1–5 minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo ""
echo "✅ Ready to ship: $DMG"
echo "   Testers: download, open, drag $DISPLAY_NAME to Applications. No warnings."
