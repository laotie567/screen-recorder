# 录屏批注助手

Chrome 扩展(MV3)+ macOS 本地宿主(Native Messaging Host)双组件方案:
**浏览器最小化(甚至退出)后,依然可以录制整个屏幕 + 系统音频 + 麦克风**。

> 纯 Chrome 扩展无法做到这一点:标签页隐藏时 Chromium 会强制暂停屏幕共享,
> 且 macOS 上扩展无法捕获系统音频。因此真正干活的是一同安装的本地宿主进程。

## 文档导航

| 文档 | 内容 |
|---|---|
| [README.md](README.md) | 功能 / 安装 / 使用 / 架构 / 限制(本文) |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 开发指南:架构、协议参考、测试、发版流程、常见开发坑 |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 故障排查:权限 / 连接 / 录制 / 菜单栏 / 安装 / 私钥 |
| [docs/DEBUG_LOG.md](docs/DEBUG_LOG.md) | 调试记录:疑难故障的根因/解法/寻源关键词(更新功能遇阻先查) |

## 功能

- **录屏**:主屏全屏,**60fps**,H.264+AAC,MP4 输出到 `~/Movies/ScreenRecord/`
  - 分辨率 = **主屏物理像素**(Retina 屏按像素录制,如 3456×2234,非逻辑点),码率按分辨率+帧率自适应(1080p60→18M / 2K60→24M / 4K60→36M;30fps 档 ×2/3)
  - 系统音频(扬声器声音)+ 麦克风画外音,双路混合为一条音轨
  - **摄像头画中画(0.3.0 新增)**:popup 勾选「同时录制摄像头」后,Mac 摄像头画面以右下角画中画合成进同一个 MP4(宽 = 屏宽 1/4,720p 采集)
  - 浏览器最小化/退出不影响录制;菜单栏红点可停止
- **截图**:主屏单帧 PNG,自动打开批注编辑器
- **批注**:画笔 / 矩形 / 箭头 / 文字 / 模糊(马赛克)/ 撤销重做 / 清空,导出 PNG 或复制剪贴板
- **文件管理**:popup 展示最近录制(大小/时间),点击在 Finder 中显示

## 环境要求

- macOS 15.0+(麦克风采集使用 ScreenCaptureKit 原生 `captureMicrophone`)
- Chrome(建议最新稳定版)
- 构建需 Xcode Command Line Tools(`xcode-select --install`)

## 安装

```bash
bash installer/install.sh
```

脚本完成:release 构建 → 打包为无窗口菜单栏 app(`~/Applications/ScreenRecordHost.app`)→
固定自签证书签名 → 注册 native messaging host。

然后:

1. 打开 `chrome://extensions`,开启「开发者模式」
2. 「加载已解压的扩展程序」,选择 `extension/` 目录
3. 点扩展图标 → 开始录制 → 按系统提示授予「屏幕录制」「麦克风」权限(用摄像头画中画还需「摄像头」)
4. **授权后需重启宿主**:菜单栏图标 → 退出,再点一次录制会自动拉起

> **「明明勾选了权限却一直报 permission denied」?** 这是旧版本 ad-hoc 签名的坑:
> macOS 按代码签名记录授权,ad-hoc 每次重装签名都变,系统设置里的旧勾选对新二进制无效。
> 0.3.0 起 install.sh 改用固定自签证书签名(授权一次永久有效)。从旧版升级请先清残留:
> `tccutil reset ScreenCapture com.screenrecord.host`(Microphone/Camera 同理),再按上面步骤授权一次。

> 扩展 ID 已通过 `manifest.json` 的固定 `key` 锁定
> (`goeagfkhaedmekekpfkhcfcoggdoneff`),与 host manifest 的
> `allowed_origins` 对应。
>
> **key 管理(重要)**:扩展私钥 `installer/extension-key.pem` **不提交到仓库**
> (.gitignore 已排除),只保留在构建者的本机。生成方式:
> `python3 installer/generate_key.py <目录>` → 把输出的公钥粘贴进
> `extension/manifest.json` 的 `"key"` 字段,并同步 `installer/install.sh`
> 的 `EXTENSION_ID`。私钥泄漏 = 任何人可伪造同 ID 扩展接管宿主,请妥善保管。

## 使用

| 操作 | 方式 |
|---|---|
| 开始/停止录制 | popup 按钮;录制中浏览器最小化后,用菜单栏红点停止 |
| 截图 | popup「截图」→ 自动打开批注页 |
| 批注 | 工具栏选工具;导出「下载 PNG」或「复制到剪贴板」 |
| 查看录制 | popup 最近录制列表,点击在 Finder 显示 |

## 架构

```
Chrome 扩展(extension/)
├── background/service-worker.js    native messaging 桥(连接管理/请求队列/事件广播)
├── popup/                          控制面板(录制/截图/列表/状态/权限引导)
└── annotate/                       批注编辑器(Canvas)

macOS 宿主(host/,Swift)
├── main.swift                      NSApplication + 后台 stdin 消息循环
├── NativeMessaging.swift           Chrome native messaging 协议(长度前缀 JSON)
├── CommandHandler.swift            命令分发 + 事件推送
├── Recorder.swift                  ScreenCaptureKit 录屏 + AVAssetWriter(+ 摄像头画中画合成)
├── CameraCapture.swift             摄像头采集(AVCaptureSession,供画中画)
├── AudioMixer.swift                系统音频+麦克风:重采样→帧对齐→混合
├── ScreenCaptureService.swift      主屏截图(SCScreenshotManager)
├── RecordingStore.swift            录制列表/Finder
├── StatusItemController.swift      菜单栏(红点/停止/退出)
└── AppInfo.swift                   目录与版本
```

通信协议(JSON):`start-record`(可带 `camera`)/ `stop-record` / `status` / `capture-screen` /
`list-recordings` / `reveal-in-finder` / `read-file`(分块,供批注页读截图)/
`check-permission` / `test-mixer`(自测);事件:`recording-started` / `recording-stopped` /
`recording-failed`。

## 测试

```bash
cd host && make test
```

- `protocol_smoke.py`:协议冒烟(握手/命令/权限拒绝/越权拒绝/音频自测)
- `check_js.swift`:扩展 JS 语法与运行冒烟(JavaScriptCore + chrome/DOM stub)
- `AudioMixer.runSelfTest`:混合逻辑数值断言(48k↔44.1k 重采样、帧对齐、相加)

有屏幕录制权限的真实录制/截图路径由冒烟测试自适应验证(有权限则录 2 秒并校验 MP4)。

## 已知限制(MVP)

- 仅主屏全屏;多显示器选择、区域录制、设置面板、全局快捷键、60fps 为后续版本
- 宿主用固定自签证书签名(本地使用,授权一次永久有效);上架 Chrome 商店需 Apple 开发者签名+隐私政策
- 首次授权后需重启宿主进程(TCC 要求)
- 宿主生命周期:Chrome 连接断开后,非录制时自动退出;录制中保持到录制结束再退出(避免重连产生双实例)。菜单栏「退出」录制中会先安全停止
