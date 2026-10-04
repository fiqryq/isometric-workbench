#!/usr/bin/env bash
# Archives Isometric Workbench and uploads it to App Store Connect / TestFlight.
#
# Usage: scripts/release.sh [--export-only]
#
# Environment:
#   TEAM_ID         Apple Developer team ID (required)
#   VERSION         marketing version, e.g. 1.0.1 (default: the project's MARKETING_VERSION)
#   BUILD_NUMBER    build number (default: seconds since epoch)
#   ASC_KEY_PATH    App Store Connect API key (.p8); with ASC_KEY_ID and ASC_ISSUER_ID,
#   ASC_KEY_ID      used for signing and uploading. Without them, Xcode's signed-in
#   ASC_ISSUER_ID   account is used.
#
# --export-only writes a signed .pkg to build/export instead of uploading.

set -euo pipefail

cd "$(dirname "$0")/.."

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/IsometricWorkbench.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
OPTIONS="$BUILD_DIR/ExportOptions.plist"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

cp ExportOptions.plist "$OPTIONS"
plutil -replace teamID -string "$TEAM_ID" "$OPTIONS"
if [[ "${1:-}" == "--export-only" ]]; then
  plutil -replace destination -string export "$OPTIONS"
fi

auth=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

version=()
if [[ -n "${VERSION:-}" ]]; then
  version=(MARKETING_VERSION="$VERSION")
fi

echo "==> Archiving build $BUILD_NUMBER"
xcodebuild archive \
  -project isometric-workbench.xcodeproj \
  -scheme isometric-workbench \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"} \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ${version[@]+"${version[@]}"}

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OPTIONS" \
  -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"}

if [[ "${1:-}" == "--export-only" ]]; then
  echo "==> Package written to $EXPORT_DIR"
else
  echo "==> Uploaded build $BUILD_NUMBER to App Store Connect"
fi
