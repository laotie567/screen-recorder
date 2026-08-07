#!/bin/bash
# 安装脚本:构建宿主 → 打包为无窗口菜单栏 app → 固定自签证书签名(失败回退 ad-hoc) →
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
    <key>CFBundleShortVersionString</key><string>0.3.2</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>录制视频时需要同步录制麦克风声音</string>
    <key>NSScreenCaptureUsageDescription</key><string>需要屏幕录制权限以录制屏幕画面</string>
    <key>NSCameraUsageDescription</key><string>开启「同时录制摄像头」时,需要摄像头权限以生成画中画画面</string>
</dict>
</plist>
PLIST

echo "==> 3/4 签名(固定证书身份,login keychain 方案)..."
# 为什么必须固定签名:macOS 的 TCC(屏幕录制/麦克风/摄像头授权)按代码签名记录,
# ad-hoc 签名每次构建 CDHash 都变 → 重装后系统设置里的旧勾选对新二进制全部失效,
# 表现为「明明勾选了权限却一直报 permission denied」。固定证书签名后授权一次永久有效。
#
# 方案演进(详见 docs/DEBUG_LOG.md D-003/D-007):
# - 旧版用「临时 keychain + set-key-partition-list」:在频繁调试的机器上会触发系统
#   钥匙串授权 GUI 弹窗(TrustedPeersHelper 卡死),install.sh 永久挂起。
# - 现版改用【login keychain 固定身份】:证书一次性导入登录钥匙串(用户配合一次),
#   之后 install.sh 直接用 `codesign --sign`,秒级完成、无 GUI、CDHash 稳定。
#   已实测:codesign 用 login keychain 身份不卡、CDHash 两次完全一致。
#
# 证书要求(macOS 15 + LibreSSL/OpenSSL 3 实测):
# - 叶子证书:basicConstraints=CA:FALSE + EKU=codeSigning(CA:TRUE 不被当 codesigning 身份)
# - 必须打包成 legacy PKCS#12(3DES)导入:分体 PEM 配不成 identity;AES p12 报 MAC verification failed
# - 自签证书的 CSSMERR_TP_NOT_TRUSTED 不影响 codesign 和 TCC(签名不需信任链,CDHash 稳定即可)
CERT_NAME="ScreenRecordHost Signing"
CERT_DIR="$HOME/.config/screenrecord-host"
KEY_PEM="$CERT_DIR/signing-key.pem"
CERT_PEM="$CERT_DIR/signing-cert.pem"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
SIGN_OK=0

# --- 第 1 步:检测 login keychain 是否已有身份(幂等:有则直接用)---
# find-identity 不带 -v 能列出未受信任的自签身份(CSSMERR_TP_NOT_TRUSTED),codesign 仍可用。
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "    检测到 login keychain 已有 $CERT_NAME 身份,直接复用"
else
    # --- 第 2 步:首次导入(用户需配合一次:输 Mac 密码 / 点「始终允许」)---
    echo "    首次使用:需要把签名证书导入登录钥匙串(只需做一次)。"

    # 2a. 生成/复用证书材料
    if [ ! -f "$KEY_PEM" ] || [ ! -f "$CERT_PEM" ]; then
        echo "    生成自签代码签名证书(保存在 $CERT_DIR)..."
        mkdir -p "$CERT_DIR" && chmod 700 "$CERT_DIR"
        if ! ( umask 077 && openssl req -x509 -newkey rsa:2048 \
            -keyout "$KEY_PEM" -out "$CERT_PEM" -days 3650 -nodes -subj "/CN=$CERT_NAME" \
            -addext "basicConstraints=critical,CA:FALSE" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" ); then
            echo "    ✗ 证书生成失败(openssl 错误见上)" >&2
            exit 1
        fi
    fi

    # 2b. 打包 legacy p12(3DES,macOS 才认)
    P12_PASS="sr$(openssl rand -hex 8 2>/dev/null || date +%s)"
    P12_FILE="$(mktemp -u -t sr-signing).p12"
    if ! openssl pkcs12 -export -legacy \
            -inkey "$KEY_PEM" -in "$CERT_PEM" \
            -out "$P12_FILE" -passout "pass:$P12_PASS" -name "$CERT_NAME" 2>/dev/null \
        || [ ! -s "$P12_FILE" ]; then
        echo "    ✗ PKCS#12 打包失败(openssl 版本过旧不支持 -legacy?用 brew install openssl@3 升级)" >&2
        rm -f "$P12_FILE" 2>/dev/null
        exit 1
    fi

    # 2c. 导入 login keychain(这一步可能弹钥匙串密码窗——输入 Mac 登录密码)
    echo "    导入证书到登录钥匙串(若弹出密码窗,请输入你的 Mac 登录密码)..."
    if ! security import "$P12_FILE" -k "$LOGIN_KC" -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security 2>&1; then
        echo "    ✗ 证书导入失败。可能是密码错误或钥匙串被锁。" >&2
        echo "      请到「钥匙串访问」App 解锁登录钥匙串后重跑本脚本。" >&2
        rm -f "$P12_FILE" 2>/dev/null
        exit 1
    fi
    rm -f "$P12_FILE" 2>/dev/null

    # 2d. 设置 partition-list:授权 codesign 免交互使用私钥(可能再弹一次确认窗,点「始终允许」)
    #     login keychain 已解锁时通常免密码;若卡住,提示用户输密码。
    echo "    授权 codesign 使用签名密钥(若弹出确认窗,点「始终允许」)..."
    # 交互式读取 login keychain 密码(非回显),用于 set-key-partition-list
    # login keychain 密码通常 = Mac 登录密码
    if [ -t 0 ]; then
        # 终端交互:读密码(非回显)
        printf "    请输入登录钥匙串密码(通常=Mac 登录密码,用于授权 codesign): "
        stty -echo 2>/dev/null
        read -r KC_PASS
        stty echo 2>/dev/null
        echo
        security set-key-partition-list -S apple-tool:,apple:,codesign:,security: \
            -s -k "$KC_PASS" "$LOGIN_KC" >/dev/null 2>&1 || true
    else
        # 非交互(管道/无头):尝试空密码(login keychain 已解锁时可能生效)
        security set-key-partition-list -S apple-tool:,apple:,codesign:,security: \
            -s -k "" "$LOGIN_KC" >/dev/null 2>&1 || true
    fi

    # 2e. 确认身份是否就绪
    if ! security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
        echo "    ✗ 导入后仍未检测到身份。请手动检查:" >&2
        echo "      钥匙串访问 → 登录钥匙串 → 证书 → 确认 \"$CERT_NAME\" 已存在且私钥可用" >&2
        exit 1
    fi
    echo "    ✓ 证书已导入登录钥匙串(后续安装将免交互)"
fi

# --- 第 3 步:用 login keychain 身份签名(秒级,无 GUI)---
if codesign --force --sign "$CERT_NAME" "$APP_DIR" 2>/dev/null; then
    # 注意:不要用 `codesign -dv | grep -q` 管道校验(pipefail + SIGPIPE 误报,见 D-003)。
    # 改写临时文件再 grep,生产者写完即正常退出。
    VERIFY_FILE="$(mktemp -t sr-verify)"
    codesign -d --verbose=4 "$APP_DIR" >"$VERIFY_FILE" 2>&1 || true
    if grep -q "Authority=$CERT_NAME" "$VERIFY_FILE"; then
        SIGN_OK=1
        echo "    已用固定证书签名(Authority=$CERT_NAME,重装不丢权限)"
    else
        echo "    ✗ 签名后未找到 Authority(身份可能未正确配置)" >&2
        sed 's/^/      /' "$VERIFY_FILE" >&2
    fi
    rm -f "$VERIFY_FILE"
else
    echo "    ✗ codesign 失败" >&2
fi

if [ "$SIGN_OK" != "1" ]; then
    echo
    echo "✗ 固定证书签名失败。这是 TCC 授权生效的前提,不能跳过(不再回退 ad-hoc)。" >&2
    echo "  排查:" >&2
    echo "  a) 身份丢失(login keychain 被清理):重跑本脚本会重新引导导入。" >&2
    echo "  b) openssl 不支持 -legacy:brew install openssl@3 后重跑。" >&2
    echo "  c) 钥匙串被锁:到「钥匙串访问」App 解锁登录钥匙串。" >&2
    echo "  详见 docs/DEBUG_LOG.md D-003/D-007。" >&2
    exit 1
fi

echo "==> 4/4 注册 native messaging host..."
NM_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$NM_DIR"
cat > "$NM_DIR/$BUNDLE_ID.json" <<JSON
{
  "name": "$BUNDLE_ID",
  "description": "录屏批注助手本地宿主(录屏/截图/系统音频/摄像头画中画)",
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
echo "  0. 若此前装过旧版本且「勾选了权限仍报错」:旧授权绑定的是失效签名,先清除残留记录"
echo "       tccutil reset ScreenCapture $BUNDLE_ID"
echo "       tccutil reset Microphone $BUNDLE_ID"
echo "       tccutil reset Camera $BUNDLE_ID"
echo "  1. 先完成本次安装(不要中途再重装)"
echo "  2. 打开 系统设置 → 隐私与安全性 → 屏幕录制 → 若已有 ScreenRecordHost 开关请先关闭再打开;"
echo "     没有则点「+」→ Cmd+Shift+G → $APP_DIR → 打开 → 勾选"
echo "  3. 麦克风 同样操作;要用摄像头画中画则「摄像头」也同样操作"
echo "  4. 本次为固定证书签名(Authority=$CERT_NAME):授权一次,之后重装/升级同一证书均有效"
echo
echo "下一步(扩展):"
echo "  1. 打开 chrome://extensions,开启「开发者模式」"
echo "  2. 「加载已解压的扩展程序」,选择: $ROOT/extension"
echo "  3. 点扩展图标 → 录屏 → 授权后如提示无法录制,重启宿主(菜单栏图标 → 退出,再点一次)"
