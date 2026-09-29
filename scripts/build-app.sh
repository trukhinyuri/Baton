#!/bin/sh
# Builds a universal (arm64 + x86_64) Baton.app into ./build. Usage: scripts/build-app.sh [version]
# CODESIGN_IDENTITY picks the signing identity ("Developer ID Application: …"); without it the app is signed ad hoc.
set -eu

cd "$(dirname "$0")/.."
. scripts/product.env
VERSION="${1:-$(cat VERSION)}"
# major.minor.patch, or a release candidate of it: major.minor.patch-rc.N.
if ! printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.[1-9][0-9]*)?$'; then
    echo 'Version must be major.minor.patch or major.minor.patch-rc.N, for example 0.2.0 or 1.0.0-rc.1.' >&2
    exit 1
fi
# Apple's version keys take only the three numbers; BatonVersion keeps the full version for --version and the report.
NUMERIC_VERSION="${VERSION%%-*}"
APP="build/$PRODUCT_NAME.app"
COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || echo dev)"
if [ "$COMMIT" != dev ] && ! git diff --quiet HEAD -- 2>/dev/null; then COMMIT="$COMMIT+dirty"; fi
# Kept apart from .build, which swift test uses, so a release build never shares its cache.
BUILD_DIR="${BATON_BUILD_DIR:-.build-app}"

# One scratch path per architecture: SwiftPM 6.4's default build system puts every architecture's products in the
# same out/Products/Release, so a second build would overwrite the first before lipo sees it.
build_arch() { # build_arch <arch>: builds both products and prints their folder
    for product in BatonApp baton; do
        swift build --scratch-path "$BUILD_DIR/$1" -c release --arch "$1" --product "$product" >&2
    done
    swift build --scratch-path "$BUILD_DIR/$1" -c release --arch "$1" --show-bin-path
}
ARM="$(build_arch arm64)"
INTEL="$(build_arch x86_64)"

rm -rf "$APP" build/*.zip build/SHA256SUMS.txt  # an archive of an earlier build must not outlive it
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
# The app target is BatonApp in SwiftPM (see Package.swift); in the bundle its executable is Baton.
lipo -create -output "$APP/Contents/MacOS/Baton" "$ARM/BatonApp" "$INTEL/BatonApp"
lipo -create -output "$APP/Contents/Helpers/baton" "$ARM/baton" "$INTEL/baton"
# Scripts written for Claude Profiles keep working in 1.x.
ln -s baton "$APP/Contents/Helpers/claude-profiles"
"$APP/Contents/Helpers/baton" __render-app-icon "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${PRODUCT_NAME}</string>
  <key>CFBundleDisplayName</key><string>${PRODUCT_NAME}</string>
  <key>CFBundleExecutable</key><string>Baton</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${NUMERIC_VERSION}</string>
  <key>CFBundleVersion</key><string>${NUMERIC_VERSION}</string>
  <key>BatonVersion</key><string>${VERSION}</string>
  <key>BatonCommit</key><string>${COMMIT}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Yuri Trukhin. MIT License.</string>
</dict>
</plist>
PLIST

# Inside out, with the hardened runtime. An ad-hoc signature is enough for apps you build yourself; distributed
# builds use a Developer ID and a secure timestamp, which notarization requires (ad-hoc signatures carry none).
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$IDENTITY" = - ]; then TIMESTAMP=--timestamp=none; else TIMESTAMP=--timestamp; fi
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP/Contents/Helpers/baton"
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP"
echo "Built $APP ($VERSION, $COMMIT, $(lipo -archs "$APP/Contents/MacOS/Baton"))"
