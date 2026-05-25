#!/usr/bin/env bash
# Build, sign, and bundle Worktree.app + a .dmg, matching the rest
# of the MattsSoftware suite's release pipeline. Run from anywhere
# — the script `cd`s to the repo root before doing anything.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/Worktree.app"
VERSION="0.1.0"
SIGN_IDENTITY="${SIGN_IDENTITY:-0948896DC970503ADEF5B5070E0BB3E9D9047757}"
DMG="$ROOT/Worktree-$VERSION.dmg"
DERIVED="$ROOT/.build/xcode"

echo "› xcodegen generate"
xcodegen generate --quiet

echo "› xcodebuild Worktree (macOS, Release)"
xcodebuild \
  -project "$ROOT/Worktree.xcodeproj" \
  -scheme Worktree \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  -quiet \
  build

BUILT="$DERIVED/Build/Products/Release/Worktree.app"
if [ ! -d "$BUILT" ]; then
  echo "✗ build produced no Worktree.app at $BUILT"; exit 1
fi
rm -rf "$APP"
ditto "$BUILT" "$APP"

if codesign --verify --strict "$APP" >/dev/null 2>&1; then
  echo "✓ signed: $(codesign -dv "$APP" 2>&1 | grep -m1 'Authority=' | sed 's/Authority=//')"
else
  echo "⚠ codesign verify failed — check signing identity"
fi
echo "✓ built $APP"

echo "› bundling $DMG"
STAGE="$(mktemp -d)/dmg"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Worktree.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Worktree" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG" || true
fi
echo "✓ built $DMG"
