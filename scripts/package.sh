#!/bin/sh
# Zips the built app for release and writes its checksum. Usage: scripts/package.sh [version]
# Run it after notarize.sh, because stapling changes the bundle.
set -eu

cd "$(dirname "$0")/.."
. scripts/product.env
VERSION="${1:-$(cat VERSION)}"
APP="build/$PRODUCT_NAME.app"
ZIP="$ARCHIVE_STEM-v$VERSION.zip"

[ -d "$APP" ] || { echo "No app at $APP. Run scripts/build-app.sh first." >&2; exit 1; }
rm -f "build/$ZIP" build/SHA256SUMS.txt
# ditto keeps the signature, extended attributes and symlinks that a plain zip would lose.
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$ZIP"
(cd build && shasum -a 256 "$ZIP" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt >/dev/null)
echo "Packaged build/$ZIP"
cat build/SHA256SUMS.txt
