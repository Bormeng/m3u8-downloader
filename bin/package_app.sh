#!/usr/bin/env bash
# package_app.sh — build the Swift binary, build the .icns, and assemble the .app bundle
set -euo pipefail

ROOT="/Users/ming/.minimax-agent-cn/projects/m3u8-downloader"
APP_NAME="m3u8 下载器"
BIN="$ROOT/SwiftApp/.build/release/M3U8Downloader"
DIST="$ROOT/dist"
BUILD="$ROOT/build"
APP_DIR="$DIST/$APP_NAME.app"
ICONSET_DIR="$BUILD/AppIcon.iconset"   # keep ASCII — iconutil chokes on non-ASCII paths
ICNS_OUT="$BUILD/AppIcon.icns"
ICON_PNG="$ROOT/docs/icon_candidate_1_geometric.png"
PYTHON_ICON_TOOLS="/tmp/icon-tools/bin/python"

echo "==> 1/5  Build Swift binary (release)"
swift build -c release --package-path "$ROOT/SwiftApp"
[[ -x "$BIN" ]] || { echo "error: binary not found at $BIN" >&2; exit 1; }

echo "==> 2/5  Build AppIcon.icns"
if [[ ! -x "$PYTHON_ICON_TOOLS" ]]; then
  echo "warning: /tmp/icon-tools venv missing; create it with:"
  echo "  uv venv /tmp/icon-tools --python 3.12"
  echo "  VIRTUAL_ENV=/tmp/icon-tools uv pip install pillow"
  exit 1
fi
mkdir -p "$ICONSET_DIR"
"$PYTHON_ICON_TOOLS" "$ROOT/bin/build_icns.py" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUT"
file "$ICNS_OUT"

echo "==> 3/5  Assemble .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Bundle the N_m3u8DL-RE binary
N_M3U8DL="/Users/ming/Movies/N_m3u8DL-RE"
if [[ -x "$N_M3U8DL" ]]; then
  cp "$N_M3U8DL" "$APP_DIR/Contents/MacOS/N_m3u8DL-RE"
  chmod +x "$APP_DIR/Contents/MacOS/N_m3u8DL-RE"
fi

# Copy the icon
cp "$ICNS_OUT" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>m3u8 下载器</string>
    <key>CFBundleDisplayName</key>      <string>m3u8 下载器</string>
    <key>CFBundleIdentifier</key>       <string>local.m3u8downloader</string>
    <key>CFBundleVersion</key>          <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleExecutable</key>       <string>m3u8 下载器</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundleIconName</key>         <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSSupportsSuddenTermination</key><true/>
    <key>NSHumanReadableCopyright</key> <string>Built on 2026-07-02</string>
</dict>
</plist>
PLIST

echo "==> 4/5  Ad-hoc codesign"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "==> 5/5  Done"
ls -la "$APP_DIR/Contents/"
ls -la "$APP_DIR/Contents/MacOS/"
ls -la "$APP_DIR/Contents/Resources/"
echo ""
echo "✅ $APP_DIR"