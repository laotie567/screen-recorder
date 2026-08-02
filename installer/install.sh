#!/bin/bash
# 安装脚本:构建宿主 → 打包为无窗口菜单栏 app → 固定证书签名(失败回退 ad-hoc) →
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

echo "==> 3/4 签名(优先固定证书,失败回退 ad-hoc)..."
# 用自签证书固定签名:ad-hoc 签名每次生成不同 CDHash,
# macOS 的屏幕录制/麦克风授权按 CDHash 记录,ad-hoc 下每次重装都需重新授权。
# 自签证书首次生成后存入登录钥匙串,之后复用,签名稳定 → 授权一次永久有效。
CERT_COMMON_NAME="ScreenRecordHost Signing"
KEYSTORE="$HOME/Library/Keychains/login.keychain-db"
SIGN_IDENTITY="" # 空 = 最终回退 ad-hoc
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_COMMON_NAME"; then
    SIGN_IDENTITY="$CERT_COMMON_NAME"
else
    echo "    首次使用:生成自签签名证书..."
    TMP_CERT_DIR="$(mktemp -d)"
    if openssl req -x509 -newkey rsa:2048 -keyout "$TMP_CERT_DIR/key.pem" -out "$TMP_CERT_DIR/cert.pem" \
            -days 3650 -nodes -subj "/CN=$CERT_COMMON_NAME" 2>/dev/null \
        && { openssl pkcs12 -export -out "$TMP_CERT_DIR/cert.p12" \
                 -inkey "$TMP_CERT_DIR/key.pem" -in "$TMP_CERT_DIR/cert.pem" -passout pass: -legacy 2>/dev/null \
             || openssl pkcs12 -export -out "$TMP_CERT_DIR/cert.p12" \
                 -inkey "$TMP_CERT_DIR/key.pem" -in "$TMP_CERT_DIR/cert.pem" -passout pass: 2>/dev/null; } \
        && security import "$TMP_CERT_DIR/cert.p12" -k "$KEYSTORE" -P "" -T /usr/bin/codesign >/dev/null 2>&1 \
        && security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_COMMON_NAME"; then
        SIGN_IDENTITY="$CERT_COMMON_NAME"
        echo "    证书已生成:$CERT_COMMON_NAME(仅本机,重装不再丢权限)"
    else
        echo "    ⚠ 自签证书生成失败(钥匙串/OpenSSL 兼容问题),回退 ad-hoc 签名:"
        echo "      每次重装需在系统设置重新勾选屏幕录制/麦克风"
    fi
    rm -rf "$TMP_CERT_DIR"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    if ! codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" 2>&1; then
        echo "    ⚠ 证书签名失败(见上方错误),回退 ad-hoc(每次重装需重新勾选权限)"
        SIGN_IDENTITY="" # 清空:最终提示按实际签名方式显示
        codesign --force --sign - "$APP_DIR"
    fi
else
    codesign --force --sign - "$APP_DIR"
fi

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
echo "📌 权限授权(重要,顺序不能反):"
echo "  1. 先完成本次安装(不要中途再重装)"
echo "  2. 打开 系统设置 → 隐私与安全性 → 屏幕录制 → 若已有 ScreenRecordHost 开关请先关闭再打开;"
echo "     没有则点「+」→ Cmd+Shift+G → $APP_DIR → 打开 → 勾选"
echo "  3. 麦克风 同样操作"
if [ -n "$SIGN_IDENTITY" ]; then
    echo "  4. 若列表已有旧记录:先删除(选中按减号),再重新添加(同一版本重装不丢权限;升级版本后仍需重新授权)"
else
    echo "  4. ⚠ 本机未能固定签名证书(已回退 ad-hoc):每次重装都需重新勾选权限"
fi
echo
echo "下一步(扩展):"
echo "  1. 打开 chrome://extensions,开启「开发者模式」"
echo "  2. 「加载已解压的扩展程序」,选择: $ROOT/extension"
echo "  3. 点扩展图标 → 录屏 → 授权后如提示无法录制,重启宿主(菜单栏图标 → 退出,再点一次)"
