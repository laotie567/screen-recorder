# 故障排查(TROUBLESHOOTING)

按「现象 → 原因 → 解决」组织。遇到问题先看这里;仍无法解决,把现象和终端输出贴给维护者。

## 1. 权限类

### 1.0 明明在系统设置里勾选了权限,却一直报 "permission denied"(最高发)

**原因**:macOS 的 TCC 按**代码签名**记录授权,系统设置列表按 bundle ID 显示。
旧版本宿主是 ad-hoc 签名,每次重装 CDHash 都变 → 列表里那条「已勾选」绑定的是**已失效的旧签名**,
对当前二进制永远无效,形成「幽灵授权」。0.3.0 起 install.sh 已改用固定自签证书签名(根治)。

**解决**(一次性):
```bash
# 1. 清除绑定旧签名的残留授权记录
tccutil reset ScreenCapture com.screenrecord.host
tccutil reset Microphone com.screenrecord.host
tccutil reset Camera com.screenrecord.host
# 2. 重新安装(0.3.0+,固定证书签名,授权一次永久有效)
bash installer/install.sh
# 3. 按安装输出的指引重新勾选 屏幕录制/麦克风/(可选)摄像头
```
之后在 chrome://extensions 刷新扩展即可。

**验证授权是否真实生效**(不依赖系统设置的勾选显示):
```bash
python3 - <<'EOF'
import json, struct, subprocess, os
env = dict(os.environ, SCREENRECORDHOST_NO_APPKIT="1")
p = subprocess.Popen([os.path.expanduser("~/Applications/ScreenRecordHost.app/Contents/MacOS/ScreenRecordHost")],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
d = json.dumps({"cmd": "check-permission"}).encode()
p.stdin.write(struct.pack("<I", len(d)) + d); p.stdin.flush()
n = struct.unpack("<I", p.stdout.read(4))[0]
print(p.stdout.read(n).decode())
p.terminate()
EOF
# {"screenRecording": true, "microphone": true, "camera": ...} 才算真的生效
```

### 1.1 「屏幕录制」列表里找不到 ScreenRecordHost

**原因**:macOS 的 TCC 列表只显示「曾经请求过权限」的应用;首次请求弹窗未成功时,列表为空,需要手动添加。

**解决**(系统设置 → 隐私与安全性 → 屏幕录制):
1. 点列表下方的「**+**」
2. 文件选择窗口按 **Cmd + Shift + G**,粘贴**绝对路径**(先确认实际安装位置,默认 `~/Applications`):
   ```
   /Users/<你的用户名>/Applications/ScreenRecordHost.app
   ```
3. 回车 → 「打开」→ 勾选 ScreenRecordHost
4. 「麦克风」同样操作;使用「同时录制摄像头」功能还需在「摄像头」中同样勾选
5. **重启宿主**:菜单栏图标 → 退出(或扩展里重新点「开始录制」自动拉起)

**提示**:宿主装在用户级 `~/Applications`,Finder 侧边栏不显示;用「前往 → 前往文件夹」输入路径查看。

### 1.2 授权后仍报 "screen recording permission denied"

**原因**:macOS 屏幕录制授权变更后,TCC 通常要求**重启进程**才生效。

**解决**:菜单栏宿主图标 → 退出 → 再点扩展「开始录制」(Chrome 会自动拉起新进程)。

### 1.3 重装/升级后权限又没了

**原因**:旧版本用 ad-hoc 签名,每次生成新的 CDHash,TCC 授权按签名记录,重装即失效。
**0.3.0 起已改用固定自签证书(授权一次永久有效)**,正常升级不会再丢权限;若仍异常,先 `tccutil reset` 三类再授权一次(见 1.0)。

### 1.4 勾选「同时录制摄像头」后点开始录制失败 / 宿主崩溃

**现象**:popup 勾选了「同时录制摄像头」,点开始录制后报 camera 相关错误,或宿主直接退出。

**原因与解决**:
- **报 `camera permission denied`**:0.3.0 新增的摄像头画中画需要**单独授权**。去
  `系统设置 → 隐私与安全性 → 摄像头` 勾选 `ScreenRecordHost`,再点一次「开始录制」。
  (不勾选该开关则只录屏幕,无需摄像头权限。)
- **宿主崩溃(SIGABRT)**:旧代码在摄像头设备被占用/权限异常时,`AVCaptureSession.startRunning()`
  会抛出 **Objective-C 异常**,而 Swift 的 `try/catch` 抓不住 ObjC 异常 → 整个进程被杀。
  **0.3.1 起用 C 桥接器(`CameraSessionBridge`)接住该异常并转为清晰的 Swift 错误**,
  宿主不再崩溃,popup 会显示具体原因(如「摄像头被其他程序占用」)。
- **摄像头被 FaceTime / Photo Booth / 其他会议软件占用**:关闭占用程序后重试。
- **报 `startRunning exception: NSGenericException: startRunning may not be called between beginConfiguration and commitConfiguration`**:
  `CameraCapture.start()` 曾用 `defer { commitConfiguration() }`,导致 `startRunning()` 落在
  `beginConfiguration/commitConfiguration` 事务内(AVFoundation 硬性禁止)。**已修复**:拆成
  配置阶段(显式 commit)与启动阶段(commit 之后才 startRunning)两步。详见 [docs/DEBUG_LOG.md D-002](DEBUG_LOG.md#d-002)。
- **报 `camera start failed: cannot add output`**(旧版残留):首次启动失败后 session 上的
  input/output 未回滚,授权后重试时 `canAddOutput` 返回 false。**已在 `start()` 开头清理残留 +
  失败分支回滚**;临时绕过:菜单栏 → 退出宿主 → 再点一次「开始录制」。

> 排查摄像头链路可看宿主日志:`~/Library/Logs/ScreenRecordHost.log`
> (启动/权限/编码失败都会写这里,Chrome 拉起宿主后 stderr 不可见,故用此日志)。

### 1.5 摄像头浮窗的使用(圆形,所见即所得)

录制中摄像头以**圆形浮窗**显示在屏幕上,所见即所得(浮窗会被屏幕录制自然捕获进 MP4)。

| 操作 | 方式 |
|---|---|
| 移动位置 | 按住浮窗主体拖动 |
| 缩放大小 | **滚轮**:在浮窗上滚动(上放大/下缩小);右下角手柄拖拽(注:手柄在某些机型不稳定,滚轮为主推方式) |
| 位置记忆 | 停止→再开录,浮窗回到上次调整后的位置/大小 |

- 浮窗层级为 statusBar,切换到其他 app(微信等)时**保持可见**(录制不中断)。
- 若浮窗在某 app 下被遮挡:检查该 app 是否用了比 statusBar 更高的私有层级(罕见);通常浮窗始终在最前。
- **不想要浮窗**:popup 取消勾选「同时录制摄像头」即可,只录屏幕+音频。

## 2. 连接类

### 2.1 popup 显示「无法连接本地宿主」

可能原因与排查(按顺序):
1. **宿主未安装**:跑 `ls ~/Applications/ScreenRecordHost.app/Contents/MacOS/ScreenRecordHost`;不存在则执行 `bash installer/install.sh`
2. **host manifest 未注册**:检查
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.screenrecord.host.json`
3. **扩展 ID 不匹配**:扩展必须用仓库 `extension/manifest.json`(含固定 key)。manifest 公钥与 install.sh 的 `EXTENSION_ID` 一致性用 `python3 installer/verify_key.py` 校验
4. **扩展未重新加载**:修改过代码后,在 chrome://extensions 点刷新按钮

### 2.2 弹出「host timeout」或「busy」

- 正常请求默认 10s 超时;首次录制(授权弹窗)与状态查询已放宽(35s/25s)
- 若持续超时:检查宿主进程是否卡死(活动监视器搜 ScreenRecordHost),杀掉后重试

### 2.3 录完一条后无法连录,必须刷新插件

**现象**:停止录制后,直接点「开始录制」无法开始下一条;刷新扩展后才能再录。

**原因**:MV3 service worker 在空闲时被 Chrome 完全终止,native messaging 连接丢失,下次操作的冷启动路径不稳。**已通过「SW 启动即预连接 + 断开后主动重连」修复**(详见 [docs/DEBUG_LOG.md D-005](DEBUG_LOG.md#d-005))。

**仍遇到时排查**:
1. 确认用的是最新 service-worker.js(修改过扩展代码后必须到 `chrome://extensions` 点刷新)
2. 录制中不要完全关闭所有 Chrome 窗口(会让 SW 加速终止)
3. 若仍必现:看 `~/Library/Logs/ScreenRecordHost.log` 最后是否有 `stdin EOF` 后无 `host started`(说明 SW 没重连),把日志末尾发给维护者

## 3. 录制类

### 3.1 录制中没有任何声音

1. 确认录制时系统**有声音在播放**(系统音频捕获的是扬声器输出)
2. 确认「麦克风」权限已授权(1.1)
3. 检查录出的 MP4 用 QuickTime 播放时音轨存在;若音轨有但音量小,属混音增益问题,反馈维护者调整 `AudioMixer.swift`

### 3.2 画面黑屏/只有声音

- 屏幕录制权限未生效:按 1.1/1.2 处理
- 多显示器:当前版本只录**主显示器**(系统设置 → 显示器 中确认主屏)

### 3.3 录到一半停止,提示 recording-failed

- 磁盘满:检查 `~/Movies/ScreenRecord/` 所在卷剩余空间
- 编码失败:查看 `~/Library/Logs` 或联系维护者

### 3.4 点「停止录制」后 popup 显示「停止中…」一直不结束

- 落盘确认依赖 `recording-stopped` 事件(文件真正写完才推);超大文件写入需要几秒
- 若超过 1 分钟:宿主可能卡死,活动监视器强制退出后检查文件是否完整

### 3.5 录制文件在哪

`~/Movies/ScreenRecord/录屏-YYYYMMDD-HHmmss.mp4`;popup 列表点击可在 Finder 中显示。

### 3.6 长录制文件打不开(提示「格式不对」)

**原因**:MP4 的索引(moov atom)只在正常停止(`finishWriting`)时写入。若录制进程被外部强杀(如系统重启前未停止、其他工具 `kill -9`),文件缺索引无法播放。旧版还存在「孤儿录制」:录制中扩展断连后,再次点「开始录制」会拉起第二个实例,旧录制永远收不到停止命令。

**已修复**:宿主现在有单实例锁(新实例启动会让旧实例安全收尾)+ SIGTERM 优雅退出(任何非强杀终止都会先保存文件)。升级到最新版后不会再出现。

**旧损坏文件**:缺 moov 的 MP4 需 untrunc 类工具 + 同参数参考文件尝试恢复,成功率低。**建议**:长录制时优先用**菜单栏红点**停止(本地操作,不依赖扩展连接),最可靠。

## 4. 菜单栏类

### 4.1 菜单栏出现两个图标 / 宿主重复启动

**原因**:旧实例未退出,Chrome 重连又拉起新实例。

**解决**:
- 安装脚本已自动 `pkill` 旧实例;手动场景:活动监视器结束所有 `ScreenRecordHost` 进程后重试
- 避免同时从多个 Chrome 窗口/配置文件连接

### 4.2 菜单栏没有图标

- 宿主未运行:点扩展「开始录制」会自动拉起
- 权限受限环境(如无 GUI 会话)不会显示菜单栏

## 5. 安装类

### 5.1 install.sh 报 `Operation not permitted`

- 当前终端用户对 `~/Applications` 无写权限;确认用本机登录用户运行,而非受限账户/sudo 提权
- 若 HOME 路径有特殊字符,确认路径存在

### 5.2 签名失败

`install.sh` 会直接显示 codesign 错误(set -e 中止)。常见原因:app bundle 路径不可写、系统安全策略拦截。可手动验证:`codesign -dv ~/Applications/ScreenRecordHost.app`

## 6. 私钥与扩展 ID

### 6.1 私钥丢了/想换 ID

1. `python3 installer/generate_key.py <目录>` 生成新 key(私钥留在本机,勿提交)
2. 把输出的公钥粘贴到 `extension/manifest.json` 的 `"key"` 字段(换行转义 `\n`)
3. 同步 `installer/install.sh` 的 `EXTENSION_ID`(脚本输出里会打印)
4. `python3 installer/verify_key.py` 校验一致
5. 重新加载扩展 + 重新安装宿主(manifest 的 allowed_origins 变了)

> 私钥在 `/tmp` 等临时位置会随重启丢失,请放到 `~/.config/screenrecord-host/` 等持久位置。

## 7. 其他

### 7.1 Chrome 更新后扩展消失

未上架扩展(本地加载)在 Chrome 大版本更新后可能被禁用;到 chrome://extensions 重新启用即可。生产分发建议上架 Chrome Web Store(需开发者签名 + 隐私政策)。
