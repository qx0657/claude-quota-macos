#!/bin/zsh
set -euo pipefail

APP_NAME="ClaudeQuotaTray"
VOLUME_NAME="Claude Quota Tray"
PUBLISH_DIR="publish"
APP_DIR="${PUBLISH_DIR}/${APP_NAME}.app"
DMG_PATH="${PUBLISH_DIR}/${APP_NAME}.dmg"
STAGING_DIR="${PUBLISH_DIR}/dmg-staging"

./build.sh release

rm -rf "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"

/usr/bin/ditto "${APP_DIR}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

/usr/bin/hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

echo "Packaged to ${DMG_PATH}"
