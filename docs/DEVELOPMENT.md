# 开发指南(DEVELOPMENT)

本文档面向「录屏批注助手」的开发者:环境准备、架构、协议、测试、发版流程与常见开发坑。

## 目录

- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [架构总览](#架构总览)
- [Native Messaging 协议](#native-messaging-协议)
- [测试](#测试)
- [发版流程](#发版流程)
- [常见开发坑](#常见开发坑)

## 环境要求

- macOS 15.0+(宿主依赖 ScreenCaptureKit 的 `captureMicrophone`,macOS 15+ 原生支持)
- Xcode Command Line Tools(`xcode-select --install`)
- Swift 5.10+(SwiftPM 构建;本机验证于 Swift 6.3)
- Chrome(加载扩展与 native messaging)

## 快速开始

```bash
# 1. 构建 + 自测(宿主协议冒烟 + JS 语法冒烟 + key 校验)
cd host && make test

# 2. 安装到本机(构建 → ~/Applications/ScreenRecordHost.app → 签名 → 注册 host manifest)
bash installer/install.sh

# 3. 加载扩展:chrome://extensions → 开发者模式 → 加载已解压的扩展程序 → extension/
```

## 架构总览

```
Chrome 扩展(extension/,MV3,原生 JS 零构建)
├── background/service-worker.js    native messaging 桥
│   ├── connect():端口生命周期 + 身份校验(port !== p,防旧端口迟到回调)
│   ├── 串行请求队列(pump):宿主为请求/响应 + 异步事件模型
│   ├── 超时处理:reject + disconnect + 重连(超时后置 port = null)
│   └── host-call 消息入口:sender.url 前缀校验 + timeoutMs 钳制 [1000,60000]
├── popup/                          控制面板(录制/截图/列表/状态/权限引导)
└── annotate/                       批注编辑器(Canvas:画笔/矩形/箭头/文字/模糊/撤销/导出)

macOS 宿主(host/,Swift,无窗口菜单栏 app)
├── main.swift                      NSApplication + 后台 stdin 消息循环
│   ├── umask(0o077):新建文件默认 0600、目录 0700
│   ├── EOF 退出策略:非录制立即退出;录制中等 recording-stopped 再退出
│   └── SCREENRECORDHOST_NO_APPKIT=1:无 UI 测试模式
├── NativeMessaging.swift           协议:4 字节小端长度前缀 + UTF-8 JSON;1MB 上限 guard
├── CommandHandler.swift            命令分发 + 事件推送(NotificationCenter → native messaging)
├── Recorder.swift                  录屏核心
│   ├── start():TCC 弹窗触发(AVCaptureScreenInput)→ 麦克风授权 → SCShareableContent → SCStream
│   ├── AVAssetWriter:H.264 + AAC,30fps,原生分辨率
│   ├── stop():stopCapture → finishWriting(完成才推送 recording-stopped)
│   ├── failWriter():writer 进入 failed(磁盘满等)主动停流推送事件
│   └── stateLock:状态字段跨线程收敛(锁外通知防死锁)
├── AudioMixer.swift                系统音频 + 麦克风混合
│   ├── AVAudioConverter:统一转 48kHz/2ch/Float32(44.1k→48k 重采样)
│   ├── 帧号对齐(pts.seconds × 48000)逐帧相加,clamp 防削波
│   ├── 单路积压上限 5s(另一路无待消费数据时丢最老)
│   └── bufferList defer 释放(noCopy 引用生命周期)
├── ScreenCaptureService.swift      主屏截图(SCScreenshotManager)→ PNG 0600
├── RecordingStore.swift            录制列表扫描 + Finder 显示
├── StatusItemController.swift      菜单栏(录制红点/停止/打开目录/退出)
└── AppInfo.swift                   版本/输出目录/数据目录

installer/
├── install.sh                      构建 → 打包 app → ad-hoc 签名 → 注册 manifest → 提示
├── generate_key.py                 生成扩展固定 key(私钥不入库)
└── verify_key.py                   校验 manifest 公钥 ↔ EXTENSION_ID(已接入 make test)
```

## Native Messaging 协议

- 传输:stdin/stdout,每条消息 = 4 字节小端 `UInt32` 长度 + UTF-8 JSON,单条 ≤ 1MB
- 握手:Chrome `connectNative` 后先发 `{"type":"connect"}`,宿主必须回 `{"type":"connect"}`

### 命令(扩展 → 宿主)

| cmd | 参数 | 响应 | 说明 |
|---|---|---|---|
| `ping` | - | `{ok, version, pid}` | 存活检查 |
| `start-record` | - | `{ok}` / `{ok:false, error}` | 异步;可能触发 TCC 授权弹窗(最长 15s) |
| `stop-record` | - | `{ok, file, duration}` | 落盘确认以 `recording-stopped` 事件为准 |
| `status` | - | `{ok, recording, recordingSince, outputDir}` | 状态快照(线程安全) |
| `capture-screen` | - | `{ok, path}` | 主屏 PNG → 中转目录 |
| `list-recordings` | - | `{ok, items:[{file,path,size,modified}]}` | 按时间倒序 |
| `reveal-in-finder` | `{path}` | `{ok}` | 仅限宿主目录白名单 |
| `read-file` | `{path, offset, size≤750000}` | `{ok, data(base64), eof}` | 分块读截图;路径白名单 + symlink 解析 |
| `test-mixer` | - | `{ok}` / `{ok:false,error}` | 音频混合自测(无需屏幕权限) |
| `quit` | - | `{ok}` | 退出宿主 |

### 事件(宿主 → 扩展,主动推送)

| event | 载荷 | 时机 |
|---|---|---|
| `recording-started` | `{file}` | startCapture 成功后 |
| `recording-stopped` | `{file, duration}` | **finishWriting 完成后**(落盘保证) |
| `recording-failed` | `{error, file?}` | writer 失败/意外停止/权限拒绝后 |
| `host-disconnected` | - | 端口断开(service worker 广播) |

## 测试

```bash
cd host && make test
```

| 测试 | 内容 |
|---|---|
| `Tests/protocol_smoke.py` | 协议冒烟:握手/ping/status/list/capture-screen 权限分支/read-file 越权拒绝/负 offset/test-mixer;有屏幕录制权限时自动真实录制 2 秒校验 MP4 |
| `Tests/check_js.swift` | 扩展 JS 语法 + 运行冒烟(JavaScriptCore + chrome/DOM stub) |
| `installer/verify_key.py` | manifest 公钥 ↔ install.sh EXTENSION_ID 密码学校验 |
| `AudioMixer.runSelfTest` | 混合数值断言:48k↔44.1k 重采样、帧对齐、0.5+0.3=0.8、积压上限截断 |

> 注意:本环境 SwiftPM manifest 沙箱不可用,`make` 已固化 `--disable-sandbox`。

## 发版流程

1. `cd host && make test` 全绿
2. 修改版本号:`host/Sources/ScreenRecordHost/AppInfo.swift` 的 `version` + `installer/install.sh` 的 `CFBundleShortVersionString`
3. `python3 installer/verify_key.py` 确认 key ↔ ID 匹配(已在 make test 内)
4. `bash installer/install.sh` 完整安装验证
5. 真机验收:录制(画面/系统声音/麦克风)、截图批注、最小化后菜单栏停止
6. 提交并打 tag:`git tag v0.1.0`

> ⚠️ 扩展私钥 `installer/extension-key.pem` 只存在于构建机,不提交仓库。丢失私钥 = 扩展 ID 变更,需重新 `generate_key.py` 并同步 `extension/manifest.json` 与 `installer/install.sh`。

## 常见开发坑

1. **TCC 弹窗不会自动出现**:只有真正调用录制 API 才弹窗。`CGPreflightScreenCaptureAccess()` 仅查询;`CGWindowListCreateImage` 在 macOS 15 起 unavailable;用 `AVCaptureScreenInput` 触发。授权后通常需重启进程生效。
2. **`AVAudioConverterOutputStatus` 语义**:有效输出常以 `.inputRanDry`(rawValue 1)结束而非 `.haveData`(0);只判断 `.haveData` 会丢数据。
3. **`CMAudioSampleBufferCreate*WithPacketDescriptions` 对线性 PCM**:packetDescriptions 传 NULL(每包固定大小);传单包描述会被按 numSamples 个包读取 → 越界。
4. **SCStreamOutputType 新 SDK 有 `.microphone`**:switch 必须穷尽。
5. **`SCShareableContent` 是 async API**,`startCapture` 是 completion 风格;`audioChannelCount` 属性名是 `channelCount`。
6. **native messaging 单条 1MB 上限**:read-file 块大小 750KB(base64 放大 4/3 后 <1MB)。
7. **状态跨线程**:Recorder 状态字段必须经 `stateLock`(withState),`notifyStatus` 锁外调用,否则订阅者回读快照会死锁。
8. **旧端口回调**:service worker 超时 disconnect 后,旧端口 onMessage/onDisconnect 可能迟到,用 `if (port !== p) return` 身份校验。
9. **升级重装**:ad-hoc 签名 CDHash 变化 → TCC 授权失效,需重新授权;安装脚本会先杀旧实例。
10. **`pgrep -F` 是 pidfile 语义**(不是固定字符串匹配),匹配进程用 `pgrep -f -x`。
