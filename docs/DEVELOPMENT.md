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
│   ├── start(camera:):SCShareableContent 触发 TCC → 麦克风授权 →(可选)摄像头授权+启动+浮窗 → SCStream
│   ├── AVAssetWriter:H.264 + AAC,60fps,物理像素分辨率,码率按分辨率+帧率自适应
│   ├── 摄像头:原生圆形浮窗(CameraOverlayPanel)+ AVCaptureVideoPreviewLayer,屏幕录制自然捕获(所见即所得),不再 CIContext 合成
│   ├── stop():stopCapture → 浮窗 hide → finishWriting(完成才推送 recording-stopped)
│   ├── failWriter():writer 进入 failed(磁盘满等)主动停流推送事件
│   ├── stopCameraIfNeeded():开始失败/停止/异常的所有出口统一回收摄像头+浮窗
│   └── stateLock:状态字段跨线程收敛(锁外通知防死锁)
├── CameraOverlayPanel.swift        圆形摄像头悬浮窗(NSPanel,statusBar level,所见即所得;拖动/滚轮缩放/手柄缩放)
├── CameraCapture.swift             摄像头采集(AVCaptureSession,720p BGRA,只保留最新帧;session 暴露给浮窗预览层)
├── AudioMixer.swift                系统音频 + 麦克风混合
│   ├── AVAudioConverter:统一转 48kHz/2ch/Float32(44.1k→48k 重采样)
│   ├── 帧号对齐(pts.seconds × 48000)逐帧相加,clamp 防削波
│   ├── 单路全消费后自动按新时间戳重置对齐基准(防音画漂移)
│   ├── 单路积压上限 5s(另一路无待消费数据时丢最老)
│   └── bufferList defer 释放(noCopy 引用生命周期)
├── ScreenCaptureService.swift      主屏截图(SCScreenshotManager)→ PNG 0600
├── RecordingStore.swift            录制列表扫描 + Finder 显示
├── StatusItemController.swift      菜单栏(录制红点/停止/打开目录/退出)
└── AppInfo.swift                   版本/输出目录/数据目录

installer/
├── install.sh                      构建 → 打包 app → 固定自签证书签名(legacy p12 + 临时钥匙串加入搜索列表,失败明确中止)→ 注册 manifest
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
| `start-record` | `{camera?}` | `{ok, camera}` / `{ok:false, error}` | 异步;可能触发 TCC 授权弹窗(最长 15s);camera=true 合成摄像头画中画 |
| `stop-record` | - | `{ok, file, duration}` | 落盘确认以 `recording-stopped` 事件为准 |
| `status` | - | `{ok, recording, camera, recordingSince, outputDir}` | 状态快照(线程安全);camera=录制中且摄像头激活 |
| `capture-screen` | - | `{ok, path}` | 主屏 PNG → 中转目录 |
| `list-recordings` | - | `{ok, items:[{file,path,size,modified}]}` | 按时间倒序 |
| `reveal-in-finder` | `{path}` | `{ok}` | 仅限宿主目录白名单 |
| `read-file` | `{path, offset, size≤750000}` | `{ok, data(base64), eof}` | 分块读截图;路径白名单 + symlink 解析 |
| `check-permission` | - | `{ok, screenRecording, microphone, camera}` | 权限真实状态(排查用) |
| `test-mixer` | - | `{ok}` / `{ok:false,error}` | 音频混合自测(无需屏幕权限) |
| `quit` | - | `{ok}` | 退出宿主 |

### 事件(宿主 → 扩展,主动推送)

| event | 载荷 | 时机 |
|---|---|---|
| `recording-started` | `{file, camera}` | startCapture 成功后 |
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

## Git 工作流(worktree)

仓库采用双分支 + 双 worktree:

| worktree | 分支 | 用途 |
|---|---|---|
| `<repo>`(主目录) | `main` | 稳定版,只合入已验收变更 |
| `<repo>-dev`(同级目录,`git worktree add ../<repo>-dev dev`) | `dev` | 日常开发,验证通过后合入 main |

常用操作:

```bash
# 查看 worktree
git worktree list

# 在 dev 中开发(两个目录可并行,各自独立构建/测试/加载扩展)
cd <repo>-dev && git checkout dev
# ... 修改、提交 ...

# 合入 main(在 dev 中完成验证后)
cd <repo> && git checkout main && git merge dev

# 删除不再需要的 dev worktree
git worktree remove <repo>-dev && git branch -d dev
```

注意:
- 每个 worktree 是独立工作副本(含独立 `host/.build`),`make test` 各自运行
- Chrome 加载的扩展目录指向哪个 worktree,就调试哪份代码(加载前先确认路径)
- 分支命名:`main`(稳定)/`dev`(开发)/`fix/<描述>`(修复)/`feat/<描述>`(功能)
- `.reasonix/`、私钥、环境脚本均不入库(.gitignore 已配置)

## 常见开发坑

> 签名/TCC/摄像头等**非显而易见的故障排查**记录在 [docs/DEBUG_LOG.md](DEBUG_LOG.md)(问题→根因→解法→寻源关键词),遇到疑难先查那里。下面是开发时高频踩的坑速查。

1. **TCC 弹窗不会自动出现**:只有真正调用录制 API 才弹窗。`CGPreflightScreenCaptureAccess()` 仅查询;`CGWindowListCreateImage` 在 macOS 15 起 unavailable;用 `SCShareableContent.excludingDesktopWindows` 触发(首次未授权时该调用本身会弹系统 TCC 授权窗,官方路径)。授权后通常需重启进程生效。详见 DEBUG_LOG D-001。
2. **`AVAudioConverterOutputStatus` 语义**:有效输出常以 `.inputRanDry`(rawValue 1)结束而非 `.haveData`(0);只判断 `.haveData` 会丢数据。
3. **`CMAudioSampleBufferCreate*WithPacketDescriptions` 对线性 PCM**:packetDescriptions 传 NULL(每包固定大小);传单包描述会被按 numSamples 个包读取 → 越界。
4. **SCStreamOutputType 新 SDK 有 `.microphone`**:switch 必须穷尽。
5. **`SCShareableContent` 是 async API**,`startCapture` 是 completion 风格;`audioChannelCount` 属性名是 `channelCount`。
6. **native messaging 单条 1MB 上限**:read-file 块大小 750KB(base64 放大 4/3 后 <1MB)。
7. **状态跨线程**:Recorder 状态字段必须经 `stateLock`(withState),`notifyStatus` 锁外调用,否则订阅者回读快照会死锁。
8. **旧端口回调**:service worker 超时 disconnect 后,旧端口 onMessage/onDisconnect 可能迟到,用 `if (port !== p) return` 身份校验。
9. **ad-hoc 签名的致命陷阱**:ad-hoc 每次构建 CDHash 都变 → TCC 授权按 CDHash 记录 → 重装后系统设置里的旧勾选对新二进制全部失效,表现「明明勾选了却报 permission denied」。**install.sh 已用固定证书签名(授权一次永久有效)**;若发现签名是 ad-hoc(`codesign -dv | grep -i authority` 无输出),见 DEBUG_LOG D-001/D-003 排查。
10. **`pgrep -F` 是 pidfile 语义**(不是固定字符串匹配),匹配进程用 `pgrep -f -x`。注意:Chrome 拉起的宿主命令行带扩展参数(`...ScreenRecordHost chrome-extension://...`),`-x` 精确匹配整行会漏;用 `pkill -f "ScreenRecordHost.app/Contents/MacOS/ScreenRecordHost"` 子串匹配更稳。
11. **macOS 代码签名身份的建立**(实测于 macOS 15 + LibreSSL,详见 DEBUG_LOG D-003):
    - 私钥裸 PEM(`-----BEGIN PRIVATE KEY-----`)用 `security import -f pemseq` 会报 `Unknown format in import`;**必须打包成 PKCS#12 一次性导入**才能在 keychain 里配对成 identity。
    - OpenSSL3/LibreSSL 默认生成的 p12 用 AES,`security import` 报 `MAC verification failed`;**必须 `openssl pkcs12 -export -legacy`**(3DES)。
    - 自签证书要做 codesigning 身份,**必须 `CA:FALSE` 叶子证书** + `codeSigning` EKU(`CA:TRUE` 会被当作 CA,`find-identity -p codesigning` 返回 0)。
    - 临时钥匙串**必须加入搜索列表**(`security list-keychains -d user -s "$TMPKC" ...`),否则即便 identity 已导入,codesign 仍报 `no identity found`(它只查搜索列表)。
12. **`set -o pipefail` + `grep -q` 的 SIGPIPE 陷阱**:`cmd | grep -q` 中 grep 匹配后退出关闭管道,生产者仍在写 → SIGPIPE → 退出码 141 → pipefail 让整条 `&&` 链判 false。**修法**:先写到临时文件再 `grep`,或 `set +o pipefail` 局部关闭。详见 DEBUG_LOG D-003。
13. **免交互 codesign 的标准姿势(实测最稳:login keychain 固定身份)**:把自签证书**一次性导入登录钥匙串**(打包成 legacy p12:`openssl pkcs12 -export -legacy`,然后 `security import -k login.keychain-db`),设一次 `set-key-partition-list` 授权 codesign(用户配合一次:输 Mac 密码 / 点「始终允许」)。之后 install.sh 直接 `codesign --sign "CN"`(从 login keychain 取身份),秒级完成、无 GUI、CDHash 稳定。**不要用临时 keychain**:频繁创建/删除 + `set-key-partition-list` 会触发系统钥匙串授权 GUI 弹窗卡死(详见 DEBUG_LOG D-007)。自签证书的 `CSSMERR_TP_NOT_TRUSTED` 不影响 codesign 和 TCC(签名不需信任链)。详见 DEBUG_LOG D-003/D-007。
14. **摄像头 `startRunning` 不能在 configuration block 内调用**:`AVCaptureSession` 在 `beginConfiguration()/commitConfiguration()` 之间调 `startRunning` 会抛 `NSGenericException`。**必须先 `commitConfiguration()` 再 `startRunning()`**。用 `defer { commitConfiguration() }` 会在 startRunning 之后才 commit,正好踩雷——用显式 `do/catch` + 显式 commit。详见 DEBUG_LOG D-002。
15. **摄像头浮窗(所见即所得)优于合成**:圆形摄像头用 `NSPanel` + `AVCaptureVideoPreviewLayer` 显示,`SCContentFilter(excludingWindows: [])` 自然捕获浮窗 → 拖动/缩放浮窗即调整 MP4 里摄像头位置大小,零延迟、零合成开销。比 CIContext 合成更简单、性能更好(旧合成路径已移除)。浮窗 level 用 `.statusBar`(非 `.floating`,后者切到其他 app 会被遮挡);`hidesOnDeactivate=false` + 监听 `didResignActive` 保活。详见 DEBUG_LOG D-006。
16. **`AVAssetWriterInput` 没有 `sourcePixelBufferAttributes` 属性**:像素缓冲属性只在 `AVAssetWriterInputPixelBufferAdaptor` 的 init 上声明。
17. **ObjC 异常对 Swift 不可见**:`AVCaptureSession.startRunning()` 等可能抛 Objective-C 异常,Swift `try/catch` 抓不住 → SIGABRT 杀进程。用独立 C/ObjC target(`CameraSessionBridge`)的 `@try/@catch` 接住,转成 `NSString*` 返回(含 name+reason),既防崩溃又可写日志诊断。SwiftPM 不允许同 target 混编 Swift+C,故拆成独立 `.target` + `publicHeadersPath`。
18. **MV3 service worker 会被完全终止(非休眠)**:停止录制/popup 关闭后,SW 在空闲时被 Chrome 销毁,所有全局状态(`port=null`)丢失。下次操作若依赖 SW 已有连接,会失败(表现为「录完一条必须刷新插件」)。**修法**:SW 顶层启动即 `connect()` 预连接 + `onDisconnect` 后 300ms 主动重连。宿主侧的 EOF 退出**不是根因**(native messaging 每次连接本就新起进程),不要在宿主侧加保活。详见 DEBUG_LOG D-005。
19. **摄像头 session 复用时 `didStartRunningNotification` 不会再发**:`AVCaptureSession` 从 stopped→running 才发该通知;若 session 已在 running(重入/上次 stop 未真正停),再调 `startRunning()` 是幂等的但不发通知 → 等通知会超时(连录失败的次生现象)。**修法**:`startRunning` 前先查 `session.isRunning`,已在跑则直接成功,不等通知。
