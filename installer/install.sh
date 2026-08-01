#!/bin/bash
# 安装脚本:构建宿主 → 打包为无窗口菜单栏 app → ad-hoc 签名 →
# 注册 Chrome native messaging host → 打印扩展加载指引。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_DIR="$ROOT/host"
APP_NAME="ScreenRecordHost"
APP_DIR="$HOME/Applications/$APP_NAME.app"
BUNDLE_ID="com.screenrecord.host"
EXTENSION_ID="goeagfkhaedmekekpfkhcfcoggdoneff" # 由本机 installer/extension-key.pem(私钥,勿提交)派生,勿改

echo "==> 1/4 构建宿主(Release)..."
( cd "$HOST_DIR" && swift build -c release --disable-sandbox )

echo "==> 2/4 打包 app bundle 到 $APP_DIR ..."
# 升级/重装:先退出运行中的旧实例,避免双实例双菜单栏图标
# 注意:macOS 的 pgrep -F 是「从 pidfile 读 PID」语义,不可用作固定字符串匹配;
# 用 -f -x 精确匹配整条命令行(宿主 argv[0] = 完整路径、无参数),避免误杀
HOST_BIN="$APP_DIR/Contents/MacOS/$APP_NAME"
if pgrep -f -x "$HOST_BIN" >/dev/null 2>&1; then
    echo "    检测到运行中的宿主,正在退出旧实例..."
    pkill -f -x "$HOST_BIN" 2>/dev/null || true
    sleep 1
fi
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$HOST_DIR/.build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>录屏批注助手宿主</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>录制视频时需要同步录制麦克风声音</string>
    <key>NSScreenCaptureUsageDescription</key><string>需要屏幕录制权限以录制屏幕画面</string>
</dict>
</plist>
PLIST

echo "==> 3/4 ad-hoc 签名(录屏/麦克风 TCC 权限按 bundle 记录)..."
codesign --force --sign - "$APP_DIR"

echo "==> 4/4 注册 native messaging host..."
NM_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$NM_DIR"
cat > "$NM_DIR/$BUNDLE_ID.json" <<JSON
{
  "name": "$BUNDLE_ID",
  "description": "录屏批注助手本地宿主(录屏/截图/系统音频)",
  "path": "$APP_DIR/Contents/MacOS/$APP_NAME",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON

echo
echo "✔ 安装完成:"
echo "  - 宿主: $APP_DIR"
echo "  - host manifest: $NM_DIR/$BUNDLE_ID.json"
echo
echo "⚠ 升级/重装提示:ad-hoc 签名每次生成新的 CDHash,"
echo "  macOS 的屏幕录制/麦克风授权按签名记录,重装后需在"
echo "  「系统设置 → 隐私与安全性」中重新勾选 ScreenRecordHost。"
echo
echo "下一步(首次):"
echo "  1. 打开 chrome://extensions,开启「开发者模式」"
echo "  2. 「加载已解压的扩展程序」,选择: $ROOT/extension"
echo "  3. 点扩展图标 → 录屏 → 首次会弹系统授权窗,分别允许「屏幕录制」「麦克风」"
echo "  4. 授权后如提示无法录制,重启宿主(菜单栏图标 → 退出,再点一次录屏自动拉起)"
