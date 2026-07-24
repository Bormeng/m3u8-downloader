#!/usr/bin/env bash
# deploy_app.sh — one-click: build → package → deploy to /Applications
#
# Usage:
#   bin/deploy_app.sh                       # deploy to /Applications/m3u8 下载器.app
#   bin/deploy_app.sh --dry-run             # build+package only, no copy / sign
#   bin/deploy_app.sh --target=/some/path   # deploy to a custom directory
#
# Behaviour:
#   - Runs `package_app.sh` first to (re)build Swift binary + assemble .app bundle
#   - Replaces any existing copy at the target path in-place (no backup kept)
#   - Copies the freshly-built bundle to /Applications/<name>.app
#   - Re-applies an ad-hoc codesign so Gatekeeper accepts it
#   - Does NOT touch any running instance of the app — launch manually when ready

set -euo pipefail

ROOT="/Users/ming/Documents/Repositories/m3u8-downloader"
APP_NAME="m3u8 下载器"           # must match package_app.sh
STAGE="$ROOT/dist/$APP_NAME.app"
TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"

DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)            DRY_RUN="true"; shift ;;
    --target=*)           TARGET_APP="${1#*=}"; TARGET_DIR="$(dirname "$TARGET_APP")"; shift ;;
    --target)             TARGET_APP="$2/$APP_NAME.app"; TARGET_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,17p' "$0"; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      sed -n '2,17p' "$0" >&2
      exit 2 ;;
  esac
done

echo "==> 1/3  Build + assemble .app"
"$ROOT/bin/package_app.sh"

if [[ ! -d "$STAGE" ]]; then
  echo "error: staged bundle missing at $STAGE" >&2
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "✅ dry-run complete: $STAGE (nothing copied to $TARGET_APP)"
  exit 0
fi

echo "==> 2/3  Replace existing copy at $TARGET_APP"
mkdir -p "$TARGET_DIR"
if [[ -e "$TARGET_APP" ]]; then
  rm -rf "$TARGET_APP"
fi
cp -R "$STAGE" "$TARGET_APP"

echo "==> 3/3  Ad-hoc codesign"
/usr/bin/codesign --force --deep --sign - "$TARGET_APP" 2>&1 | tail -3 || true
/usr/bin/codesign --verify --verbose=2 "$TARGET_APP" 2>&1 | tail -3 || true

echo ""
echo "✅ deployed: $TARGET_APP"
echo "   to launch:  open \"$TARGET_APP\""
echo "   (running instance was NOT touched — quit & relaunch yourself if needed)"