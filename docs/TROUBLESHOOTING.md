# 故障排查(TROUBLESHOOTING)

按「现象 → 原因 → 解决」组织。遇到问题先看这里;仍无法解决,把现象和终端输出贴给维护者。

## 1. 权限类

### 1.1 「屏幕录制」列表里找不到 ScreenRecordHost

**原因**:macOS 的 TCC 列表只显示「曾经请求过权限」的应用;首次请求弹窗未成功时,列表为空,需要手动添加。

**解决**(系统设置 → 隐私与安全性 → 屏幕录制):
1. 点列表下方的「**+**」
2. 文件选择窗口按 **Cmd + Shift + G**,粘贴**绝对路径**(先确认实际安装位置,默认 `~/Applications`):
   ```
   /Users/<你的用户名>/Applications/ScreenRecordHost.app
   ```
3. 回车 → 「打开」→ 勾选 ScreenRecordHost
4. 「麦克风」同样操作
5. **重启宿主**:菜单栏图标 → 退出(或扩展里重新点「开始录制」自动拉起)

**提示**:宿主装在用户级 `~/Applications`,Finder 侧边栏不显示;用「前往 → 前往文件夹」输入路径查看。

### 1.2 授权后仍报 "screen recording permission denied"

**原因**:macOS 屏幕录制授权变更后,TCC 通常要求**重启进程**才生效。

**解决**:菜单栏宿主图标 → 退出 → 再点扩展「开始录制」(Chrome 会自动拉起新进程)。

### 1.3 重装/升级后权限又没了

**原因**:ad-hoc 签名每次生成新的 CDHash,TCC 授权按签名记录,重装即失效。

**解决**:按 1.1 重新添加(装完 `install.sh` 后列表里通常已有旧记录,重新勾选或删除重加)。

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
