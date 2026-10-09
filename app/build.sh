#!/bin/bash
# Claude Status（ClaudeStatus.app）をビルドする。
#   app/build.sh             app/build/ClaudeStatus.app を作る
#   app/build.sh --install   さらに ~/Applications に入れて起動する（起動中なら入れ替える）
#
# 必要なもの: Xcode または Command Line Tools（swift）
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$APP_DIR")"
NAME="ClaudeStatus"
BUNDLE_ID="io.github.sakai419.claude-status"
OUT="$APP_DIR/build/$NAME.app"
DEST="$HOME/Applications/$NAME.app"

install=0
case "${1:-}" in
  --install) install=1 ;;
  "") ;;
  *) echo "使い方: $0 [--install]" >&2; exit 1 ;;
esac

swift build -c release --package-path "$APP_DIR"
bin_dir="$(swift build -c release --package-path "$APP_DIR" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$bin_dir/$NAME" "$OUT/Contents/MacOS/$NAME"

plist="$OUT/Contents/Info.plist"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Claude Status</string>
  <key>CFBundleDisplayName</key><string>Claude Status</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
# 一覧から消したときに status.md を作り直すため、この repo の bin/ を教えておく。
# パスに特殊文字があっても壊れないよう、plist への書き込みは plutil に任せる。
plutil -insert ClaudeStatusBin -string "$REPO/bin" "$plist"

# 配布用の署名ではなく、ローカルで動かすためのアドホック署名
codesign --force --sign - "$OUT" >/dev/null 2>&1
echo "ビルドしました: $OUT"

[ "$install" -eq 1 ] || exit 0

if pgrep -xq "$NAME"; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || pkill -x "$NAME" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq "$NAME" || break; sleep 0.3; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$OUT" "$DEST"
open "$DEST"
echo "インストールして起動しました: $DEST"
