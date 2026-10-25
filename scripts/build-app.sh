#!/bin/bash
# Builds build/StorageSpaces.app and build/StorageSpaces.zip (what a release carries). Needs a Mac with Xcode or
# its Command Line Tools; GitHub Actions runs it on every push, so nobody has to build anything
# by hand.
#
#   VERSION=0.1.7 scripts/build-app.sh
#
# UNIVERSAL=0 builds for this Mac's chip only (works with just the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
BRANCH="${BRANCH:-main}"
NAME=StorageSpaces
APP="build/$NAME.app"
# CFBundleVersion must be numbers with dots: VERSION's leading numbers (0.1-abc1234 → 0.1), or 0.
if [[ "$VERSION" =~ ^([0-9]+(\.[0-9]+){0,2}) ]]; then BUNDLE_VERSION="${BUNDLE_VERSION:-${BASH_REMATCH[1]}}"; else BUNDLE_VERSION="${BUNDLE_VERSION:-0}"; fi

# A value as it can go inside the plist's XML.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }

command -v swift >/dev/null 2>&1 || {
  echo "error: building needs Swift. Install Apple's command line tools (xcode-select --install), then try again." >&2
  exit 3
}

if [[ "${UNIVERSAL:-1}" == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi
swift build -c release --product "$NAME" ${ARCHS[@]+"${ARCHS[@]}"}
BINDIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/$NAME" "$APP/Contents/MacOS/$NAME"
# The docs it serves at /api/doc and /api/docs/{name}.
mkdir -p "$APP/Contents/Resources/docs"
cp API.md docs/*.md "$APP/Contents/Resources/docs/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ainigh.storage-spaces</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>Storage Spaces</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(xml "$VERSION")</string>
  <key>CFBundleVersion</key><string>$(xml "$BUNDLE_VERSION")</string>
  <key>StorageCommit</key><string>$(xml "$COMMIT")</string>
  <key>StorageBranch</key><string>$(xml "$BRANCH")</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: Apple silicon only runs signed code, and this needs no developer account. Its
# designated requirement is the bundle id alone (not this build's hash), so what macOS has allowed
# the app (notifications, the Desktop folder) carries over to the next version.
BUNDLE_ID=com.ainigh.storage-spaces
codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "built $APP ($VERSION, $BRANCH, $COMMIT)"
