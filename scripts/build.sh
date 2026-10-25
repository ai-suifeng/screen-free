#!/bin/zsh
# Generates the Xcode project and builds Takes.app into build/.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
KC="$HOME/Library/Keychains/takes-signing.keychain-db"
if [[ ! -f "$KC" ]]; then ./scripts/setup-signing.sh; fi
security unlock-keychain -p takes-local "$KC"
xcodegen generate --quiet
if [[ "$CONFIG" == Release ]]; then
  # Universal binary for downloads: Apple silicon and Intel.
  xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Release \
    -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
else
  xcodebuild -project Takes.xcodeproj -scheme Takes -configuration "$CONFIG" \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' build -quiet
fi
rm -rf build/Takes.app
cp -R "build/DerivedData/Build/Products/$CONFIG/Takes.app" build/Takes.app

# Sign with the stable local identity (see setup-signing.sh) so macOS permissions survive rebuilds.
if security find-certificate -c "Takes Local Signing" "$KC" >/dev/null 2>&1; then
  codesign --force --deep --sign "Takes Local Signing" --keychain "$KC" \
    --entitlements Takes/Resources/Takes.entitlements build/Takes.app
else
  echo "warning: run scripts/setup-signing.sh once, or permissions reset after every build" >&2
fi
echo "Built build/Takes.app"
