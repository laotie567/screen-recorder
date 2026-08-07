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

echo "==> 3/4 签名(固定自签证书身份)..."
# 为什么必须固定签名:macOS 的 TCC(屏幕录制/麦克风/摄像头授权)按代码签名记录,
# ad-hoc 签名每次构建 CDHash 都变 → 重装后系统设置里的旧勾选对新二进制全部失效,
# 表现为「明明勾选了权限却一直报 permission denied」。固定证书签名后授权一次永久有效。
#
# 实现要点(macOS 15 + LibreSSL/OpenSSL 3 实测,2026-08 验证通过):
# - 证书必须是【叶子证书】:basicConstraints=CA:FALSE + EKU=codeSigning。
#   CA:TRUE 会被 keychain 当作 CA 而非可用的 codesigning 身份(find-identity 返回 0)。
# - 私钥/证书分体 PEM 用 security import 分两次导入,keychain 无法把它们配对成身份
#   (find-identity 仍返回 0)。必须打包成 PKCS#12 一次性导入。
# - LibreSSL/OpenSSL3 默认生成的 p12 用 AES-256-CBC,macOS security import 报
#   "MAC verification failed"。必须用 `openssl pkcs12 -export -legacy`(3DES)
#   才能被 macOS 识别。
# - 临时钥匙串必须加入 keychain 搜索列表(list-keychains -s),否则即使 identity
#   已导入,codesign 仍报 "no identity found"(它只查搜索列表,不查孤立 keychain)。
# - set-key-partition-list 授权 codesign 免确认使用私钥(不设置会卡 GUI 授权窗)。
# - 证书材料持久保存在 ~/.config/screenrecord-host/(0600),每次安装复用同一证书。
CERT_NAME="ScreenRecordHost Signing"
CERT_DIR="$HOME/.config/screenrecord-host"
KEY_PEM="$CERT_DIR/signing-key.pem"
CERT_PEM="$CERT_DIR/signing-cert.pem"
SIGN_OK=0

# 生成叶子证书(CA:FALSE)。注意:若已存在旧版 CA:TRUE 证书会保留——
# 旧证书的私钥 PEM 格式 + CA 标志会导致下面签名失败,届时会进入错误中止分支提示重新生成。
if [ ! -f "$KEY_PEM" ] || [ ! -f "$CERT_PEM" ]; then
    echo "    首次使用:生成自签代码签名证书(保存在 $CERT_DIR)..."
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

if [ -f "$KEY_PEM" ] && [ -f "$CERT_PEM" ]; then
    TMPKC_PASS="sr$(openssl rand -hex 8 2>/dev/null || date +%s)"
    P12_PASS="sr$(openssl rand -hex 8 2>/dev/null || date +%s)"
    TMPKC="$(mktemp -u -t sr-signing).keychain"
    P12_FILE="$(mktemp -u -t sr-signing).p12"

    # 捕获原始搜索列表,用数组保存避免 word-splitting/路径转义破坏
    # (旧版直接字符串拼接 $BEFORE_LIST,路径里的空格/引号会把 list-keychains -s 参数搞乱,
    #  污染用户 keychain 搜索列表)。cleanup 钩子保证无论如何都恢复。
    ORIG_SEARCH=()
    while IFS= read -r line; do
        # security list-keychains 输出形如:    "/path/to/kc.db"
        ORIG_SEARCH+=( "$(printf '%s' "$line" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')" )
    done < <(security list-keychains -d user 2>/dev/null)

    restore_search_list() {
        if [ "${#ORIG_SEARCH[@]}" -gt 0 ]; then
            security list-keychains -d user -s "${ORIG_SEARCH[@]}" 2>/dev/null || true
        fi
    }
    cleanup_signing() {
        restore_search_list
        security delete-keychain "$TMPKC" >/dev/null 2>&1 || true
        rm -f "$TMPKC" "${TMPKC}-db" "$P12_FILE" 2>/dev/null || true
    }

    if security create-keychain -P "$TMPKC_PASS" "$TMPKC" 2>/dev/null; then
        security unlock-keychain -p "$TMPKC_PASS" "$TMPKC" 2>/dev/null || true

        # 关键 1:打包成 legacy PKCS#12(3DES),macOS security import 才认。
        # 分体 PEM 两次 import 无法配对成 identity;默认 AES p12 报 MAC verification failed。
        if openssl pkcs12 -export -legacy \
                -inkey "$KEY_PEM" -in "$CERT_PEM" \
                -out "$P12_FILE" -passout "pass:$P12_PASS" -name "$CERT_NAME" 2>/dev/null \
            && [ -s "$P12_FILE" ]; then

            if security import "$P12_FILE" -k "$TMPKC" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null 2>&1; then
                # 分区列表:授权 codesign 免 GUI 确认使用私钥(不设置会弹授权窗或直接失败)
                security set-key-partition-list -S apple-tool:,apple:,codesign:,security: \
                    -s -k "$TMPKC_PASS" "$TMPKC" >/dev/null 2>&1 || true

                # 关键 2:临时 keychain 必须加入搜索列表,否则 codesign 找不到 identity
                # (codesign 只查搜索列表中的 keychain,不查 --keychain 指定的孤立 keychain)。
                security list-keychains -d user -s "$TMPKC" "${ORIG_SEARCH[@]}" 2>/dev/null || true

                # 注意:不要用 `codesign -dv ... | grep -q` 管道校验。
                # 原因:set -o pipefail 下,grep -q 匹配到即退出会关闭读端,
                # codesign 仍在写 → 收到 SIGPIPE → 退出码 141 → pipefail 让整条管道
                # 退出码 = 141 → 外层 && 链判 false,签名明明成功却误报失败。
                # 修法:把签名信息写到临时文件再 grep,生产者写完即正常退出,无 SIGPIPE。
                if codesign --keychain "$TMPKC" --force --sign "$CERT_NAME" "$APP_DIR" 2>/dev/null; then
                    VERIFY_FILE="$(mktemp -t sr-verify)"
                    codesign -d --verbose=4 "$APP_DIR" >"$VERIFY_FILE" 2>&1 || true
                    if grep -q "Authority=$CERT_NAME" "$VERIFY_FILE"; then
                        SIGN_OK=1
                        echo "    已用固定证书签名(Authority=$CERT_NAME,重装不再丢权限)"
                    fi
                    rm -f "$VERIFY_FILE"
                fi
            fi
        fi
        cleanup_signing
    fi
fi

if [ "$SIGN_OK" != "1" ]; then
    # 不再静默回退 ad-hoc:ad-hoc 是本 bug 的根因(重装即丢权限),回退只会让问题重现。
    # 明确中止,给出可操作的修复指引。
    echo
    echo "✗ 固定证书签名失败。这是 TCC 授权生效的前提,不能跳过。" >&2
    echo "  常见原因:" >&2
    echo "  a) 旧版 CA:TRUE 证书残留(~/.config/screenrecord-host/),与新版流程不兼容。" >&2
    echo "     删除后重跑本脚本即可重新生成:" >&2
    echo "       rm -rf ~/.config/screenrecord-host && $0" >&2
    echo "  b) openssl 版本过旧不支持 -legacy(需要 openssl 3.x;LibreSSL 亦支持)。" >&2
    echo "     openssl version → 若 < 3,用 brew install openssl@3 升级。" >&2
    echo "  c) 本机禁用了临时 keychain 创建。" >&2
    echo
    echo "  失败的详细日志(可重新跑本脚本并查看此处以上输出)。" >&2
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
