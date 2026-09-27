#!/bin/sh
# Builds Claude Profiles.app into ./build. Usage: scripts/build-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
VERSION="${1:-$(cat VERSION)}"
case "$VERSION" in
    ''|*[!0-9.]*)
        echo 'Version must be major.minor.patch, for example 0.2.0.' >&2
        exit 1
        ;;
esac
if ! printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    echo 'Version must be major.minor.patch, for example 0.2.0.' >&2
    exit 1
fi
APP="build/Claude Profiles.app"
BUILD_DIR="${CLAUDE_PROFILES_BUILD_DIR:-.build}"

swift build --scratch-path "$BUILD_DIR" -c release --product ClaudeProfiles
swift build --scratch-path "$BUILD_DIR" -c release --product claude-profiles
BIN="$(swift build --scratch-path "$BUILD_DIR" -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/ClaudeProfiles" "$APP/Contents/MacOS/ClaudeProfiles"
cp "$BIN/claude-profiles" "$APP/Contents/Helpers/claude-profiles"
"$BIN/claude-profiles" __render-app-icon "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.trukhinyuri.claudeprofiles</string>
  <key>CFBundleName</key><string>Claude Profiles</string>
  <key>CFBundleDisplayName</key><string>Claude Profiles</string>
  <key>CFBundleExecutable</key><string>ClaudeProfiles</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for apps you build yourself. Distributed builds should use a Developer ID.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/Helpers/claude-profiles"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION)"
