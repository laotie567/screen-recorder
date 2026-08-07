# 录屏批注助手 / Screen Record & Annotate

[English](#english) | [中文](#中文)

---

<a id="中文"></a>

## 中文

Chrome 扩展(MV3)+ macOS 本地宿主(Native Messaging Host)双组件方案:
**浏览器最小化(甚至退出)后,依然可以录制整个屏幕 + 系统音频 + 麦克风**,并支持圆形摄像头浮窗、截图与批注。

> 纯 Chrome 扩展做不到这一点:标签页隐藏时 Chromium 会强制暂停屏幕共享,且 macOS 上扩展无法捕获系统音频。因此真正干活的是一同安装的本地宿主进程。

### ✨ 功能

- **高清录屏**:主屏全屏,**物理像素级**(Retina 屏 3024×1964,非逻辑点),60fps,H.264+AAC,MP4 输出到 `~/Movies/ScreenRecord/`
  - 系统音频(扬声器声音)+ 麦克风画外音,双路混合为一条音轨
  - **圆形摄像头浮窗(所见即所得)**:勾选「同时录制摄像头」后,摄像头以圆形悬浮窗显示在屏幕上,拖动/滚轮缩放即调整 MP4 里摄像头的位置和大小,切换窗口时保持可见
  - 浏览器最小化/退出不影响录制;菜单栏红点可停止
- **截图**:主屏单帧 PNG(物理像素级),自动打开批注编辑器
- **批注**:画笔 / 矩形 / 箭头 / 文字 / 模糊(马赛克)/ 撤销重做 / 清空,导出 PNG 或复制剪贴板
- **文件管理**:popup 展示最近录制(大小/时间),点击在 Finder 中显示

### 📋 环境要求

- macOS 15.0+(麦克风采集使用 ScreenCaptureKit 原生 `captureMicrophone`)
- Chrome(建议最新稳定版)
- 构建需 Xcode Command Line Tools(`xcode-select --install`)

### 🚀 安装

```bash
git clone https://github.com/laotie567/screen-recorder.git
cd screen-recorder
bash installer/install.sh
```

脚本完成:release 构建 → 打包为无窗口菜单栏 app(`~/Applications/ScreenRecordHost.app`)→ 固定证书签名(login keychain,授权一次永久有效)→ 注册 native messaging host。

然后:

1. 打开 `chrome://extensions`,开启「开发者模式」
2. 「加载已解压的扩展程序」,选择 `extension/` 目录
3. 点扩展图标 → 开始录制 → 按系统提示授予「屏幕录制」「麦克风」权限(用摄像头浮窗还需「摄像头」)
4. **首次签名**:install.sh 会引导把签名证书导入登录钥匙串(输 Mac 密码 + 点「始终允许」,只做一次)

> **「明明勾选了权限却一直报 permission denied」?** 这是 ad-hoc 签名的坑(详见 [TROUBLESHOOTING](docs/TROUBLESHOOTING.md#10))。用最新 install.sh(login keychain 固定签名)+ `tccutil reset` 清残留即可根治。

### 📖 使用

| 操作 | 方式 |
|---|---|
| 开始/停止录制 | popup 按钮;录制中浏览器最小化后,用菜单栏红点停止 |
| 截图 | popup「截图」→ 自动打开批注页 |
| 批注 | 工具栏选工具;导出「下载 PNG」或「复制到剪贴板」 |
| 摄像头浮窗 | popup 勾选「同时录制摄像头」;录制中拖动改位置、滚轮缩放 |
| 查看录制 | popup 最近录制列表,点击在 Finder 显示 |

### 🏗️ 架构

```
Chrome 扩展(extension/,MV3,原生 JS 零构建)
├── background/service-worker.js    native messaging 桥(连接管理/请求队列/事件广播)
├── popup/                          控制面板(录制/截图/列表/状态/权限引导)
└── annotate/                       批注编辑器(Canvas)

macOS 宿主(host/,Swift)
├── main.swift                      NSApplication + 后台 stdin 消息循环
├── NativeMessaging.swift           Chrome native messaging 协议(长度前缀 JSON)
├── CommandHandler.swift            命令分发 + 事件推送
├── Recorder.swift                  ScreenCaptureKit 录屏 + AVAssetWriter
├── CameraOverlayPanel.swift        圆形摄像头浮窗(NSPanel,所见即所得;拖动/缩放)
├── CameraCapture.swift             摄像头采集(AVCaptureSession,供浮窗预览)
├── AudioMixer.swift                系统音频+麦克风:重采样→帧对齐→混合
├── ScreenCaptureService.swift      主屏截图(SCScreenshotManager)
├── RecordingStore.swift            录制列表/Finder
├── StatusItemController.swift      菜单栏(红点/停止/退出)
└── AppInfo.swift                   目录与版本
```

通信协议(JSON over native messaging):`start-record`(可带 `camera`)/ `stop-record` / `status` / `capture-screen` / `list-recordings` / `reveal-in-finder` / `read-file` / `check-permission`;事件:`recording-started` / `recording-stopped` / `recording-failed`。详见 [DEVELOPMENT.md](docs/DEVELOPMENT.md#native-messaging-协议)。

### 📚 文档

| 文档 | 内容 |
|---|---|
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 开发指南:架构、协议参考、测试、发版流程、常见开发坑 |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 故障排查:权限 / 连接 / 录制 / 菜单栏 / 安装 / 私钥 |
| [docs/DEBUG_LOG.md](docs/DEBUG_LOG.md) | 调试记录:疑难故障的根因/解法/寻源关键词(更新功能遇阻先查) |

### ⚠️ 已知限制(MVP)

- 仅主屏全屏;多显示器选择、区域录制、设置面板、全局快捷键为后续版本
- 宿主用固定自签证书签名(本地使用,授权一次永久有效);上架 Chrome 商店需 Apple 开发者签名 + 隐私政策
- 首次授权后需重启宿主进程(TCC 要求)

---

<a id="english"></a>

## English

A Chrome Extension (MV3) + macOS native messaging host that lets you **record the full screen + system audio + microphone even when the browser is minimized or closed**, with a circular camera overlay, screenshots, and annotations.

> A pure Chrome extension can't do this: Chromium pauses screen sharing when a tab is hidden, and extensions can't capture system audio on macOS. The real work is done by a companion native host process.

### ✨ Features

- **High-res screen recording**: full main display at **physical pixel resolution** (e.g. 3024×1964 on Retina, not logical points), 60fps, H.264+AAC, MP4 to `~/Movies/ScreenRecord/`
  - System audio (speaker output) + microphone voiceover, mixed into one track
  - **Circular camera overlay (WYSIWYG)**: toggle "record camera" and a circular floating window shows the camera feed. Drag/scroll to reposition and resize — what you see is what gets recorded. Stays visible across window switches.
  - Browser minimize/quit doesn't stop recording; stop via menu bar red dot
- **Screenshot**: single-frame PNG at physical pixel resolution, auto-opens annotation editor
- **Annotation**: pen / rectangle / arrow / text / blur (mosaic) / undo-redo / clear, export PNG or copy to clipboard
- **File management**: popup shows recent recordings (size/time), click to reveal in Finder

### 📋 Requirements

- macOS 15.0+ (uses ScreenCaptureKit's native `captureMicrophone`)
- Chrome (latest stable recommended)
- Xcode Command Line Tools to build (`xcode-select --install`)

### 🚀 Install

```bash
git clone https://github.com/laotie567/screen-recorder.git
cd screen-recorder
bash installer/install.sh
```

The script: release build → packages a windowless menu-bar app (`~/Applications/ScreenRecordHost.app`) → fixed-certificate signing (login keychain, authorize once and it sticks across reinstalls) → registers the native messaging host.

Then:

1. Open `chrome://extensions`, enable "Developer mode"
2. "Load unpacked", select the `extension/` directory
3. Click the extension icon → Start recording → grant Screen Recording / Microphone permissions (Camera too if using the overlay)
4. **First-time signing**: install.sh guides you to import the signing cert into your login keychain (enter your Mac password + click "Always Allow", one-time only)

> **"Granted permission but still denied"?** This is the ad-hoc signing pitfall (see [TROUBLESHOOTING](docs/TROUBLESHOOTING.md)). Use the latest install.sh (login keychain fixed signing) + `tccutil reset` to clean residue.

### 📖 Usage

| Action | How |
|---|---|
| Start/stop recording | popup button; when minimized, stop via menu bar red dot |
| Screenshot | popup "Screenshot" → auto-opens annotation page |
| Annotate | pick a tool; export "Download PNG" or "Copy to clipboard" |
| Camera overlay | toggle "Record camera" in popup; drag to move, scroll to resize during recording |
| View recordings | popup recent list, click to reveal in Finder |

### 🏗️ Architecture

```
Chrome Extension (extension/, MV3, vanilla JS, no build step)
├── background/service-worker.js    native messaging bridge (conn mgmt / request queue / event broadcast)
├── popup/                          control panel (record/screenshot/list/status/permission guide)
└── annotate/                       annotation editor (Canvas)

macOS Host (host/, Swift)
├── main.swift                      NSApplication + background stdin message loop
├── NativeMessaging.swift           Chrome native messaging protocol (length-prefixed JSON)
├── CommandHandler.swift            command dispatch + event push
├── Recorder.swift                  ScreenCaptureKit capture + AVAssetWriter
├── CameraOverlayPanel.swift        circular camera overlay (NSPanel, WYSIWYG; drag/resize)
├── CameraCapture.swift             camera capture (AVCaptureSession, feeds overlay preview)
├── AudioMixer.swift                system audio + mic: resample → align → mix
├── ScreenCaptureService.swift      main display screenshot (SCScreenshotManager)
├── RecordingStore.swift            recording list / Finder reveal
├── StatusItemController.swift      menu bar (red dot / stop / quit)
└── AppInfo.swift                   directories & version
```

Protocol (JSON over native messaging): `start-record` (optional `camera`) / `stop-record` / `status` / `capture-screen` / `list-recordings` / `reveal-in-finder` / `read-file` / `check-permission`; events: `recording-started` / `recording-stopped` / `recording-failed`. See [DEVELOPMENT.md](docs/DEVELOPMENT.md).

### 📚 Docs

| Doc | Contents |
|---|---|
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Dev guide: architecture, protocol reference, tests, release flow, common pitfalls |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Troubleshooting: permissions / connection / recording / menu bar / install / keys |
| [docs/DEBUG_LOG.md](docs/DEBUG_LOG.md) | Debug log: root-cause records for tricky bugs (check here first when stuck) |

### ⚠️ Known limitations (MVP)

- Main display only; multi-monitor selection, region recording, settings panel, global hotkeys are future work
- Host is signed with a fixed self-signed cert (for local use, authorize once); Chrome Web Store listing requires an Apple Developer cert + privacy policy
- First authorization requires a host process restart (TCC requirement)

### 📄 License

MIT — see [LICENSE](LICENSE).
