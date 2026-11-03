#!/bin/bash
# 构建「合盖不休眠.app」：把 SwiftUI 面板 + 各脚本/二进制打包成一个 macOS 应用
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="合盖不休眠"
APP="${APP_NAME}.app"
EXE="$APP/Contents/MacOS/$APP_NAME"
RES="$APP/Contents/Resources"

echo "== 1/5 编译 SwiftUI 面板 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
/usr/bin/swiftc -O -parse-as-library -o "$EXE" app/App.swift \
  -framework SwiftUI -framework AppKit -framework Foundation

echo "== 2/5 写入 Info.plist =="
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>com.yyz.keepawake.app</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>本地工具 · yyz</string>
</dict>
</plist>
PLIST

echo "== 3/5 打包脚本与二进制 =="
cp -f bin/vdisp bin/setbright bin/mirror bin/capprobe "$RES/"
cp -f .lidwatch.sh "$RES/lidwatch.sh"
cp -f .admin-enable.sh "$RES/admin-enable.sh"
cp -f .admin-disable.sh "$RES/admin-disable.sh"
chmod 755 "$RES/lidwatch.sh" "$RES/admin-enable.sh" "$RES/admin-disable.sh" "$RES/vdisp" "$RES/setbright" "$RES/mirror" "$RES/capprobe"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== 4/5 生成应用图标 =="
if [ -f app/icon.png ]; then
  rm -rf /tmp/yzapp.iconset && mkdir -p /tmp/yzapp.iconset
  for s in 16 32 64 128 256 512; do
    /usr/bin/sips -z $s $s app/icon.png --out "/tmp/yzapp.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    /usr/bin/sips -z $d $d app/icon.png --out "/tmp/yzapp.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns /tmp/yzapp.iconset -o "$RES/app.icns" && \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string app.icns" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

echo "== 5/5 签名（ad-hoc）=="
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "（签名失败，仍可本机运行）"
echo "✅ 构建完成：$(pwd)/$APP"
echo "   双击打开：open '$APP'"
