# 调试记录(DEBUG_LOG)

> 本文档按时间倒序记录**非显而易见的故障排查**,供后续功能更新遇到类似问题时寻源。
> 每条记录包含:现象 / 排查命令 / 根因 / 修复 / 寻源关键词。
> 日常小修不必登记;登记标准是「下次遇到同类问题会卡住超过 10 分钟」的坑。

## 目录

- [D-001 录屏/截图全部失效,报「用户拒绝了 TCC」](#d-001)
- [D-002 摄像头录制报 `startRunning threw exception`](#d-002)
- [D-003 install.sh 固定签名静默失败(从未真正成功过)](#d-003)
- [D-004 摄像头 `startRunning` 异步竞态(中间态,被 D-002 根因取代)](#d-004)

---

<a id="d-001"></a>
## D-001 录屏/截图全部失效,报「用户拒绝了应用程序、窗口、显示器捕捉的TCC」(2026-08-07)

### 现象
- 用户已在「系统设置 → 隐私与安全性 → 屏幕录制」勾选 ScreenRecordHost,但点「开始录制」「截图」仍失败。
- popup 显示「权限均已授权,但录制启动失败」。
- 宿主日志 `~/Library/Logs/ScreenRecordHost.log` 反复出现:
  ```
  recorder: SCShareableContent failed: 用户拒绝了应用程序、窗口、显示器捕捉的TCC
  start-record: FAILED: screen recording permission denied
  ```

### 关键排查命令
```bash
# 1. 看宿主日志(最重要,Chrome 拉起的宿主 stderr 不可见)
tail -n 50 ~/Library/Logs/ScreenRecordHost.log

# 2. 查已安装 app 的真实签名类型(adhoc 还是固定证书)
codesign -d --verbose=4 ~/Applications/ScreenRecordHost.app 2>&1 | grep -iE "Authority|Flags|CDHash"
#   ad-hoc 的特征:Flags=0x2(adhoc),Signature=adhoc,无 Authority 行
#   固定证书:Flags=0x0(none),Authority=ScreenRecordHost Signing

# 3. 直接查权限真实状态(绕过系统设置的勾选显示)
SCREENRECORDHOST_NO_APPKIT=1 ~/Applications/ScreenRecordHost.app/Contents/MacOS/ScreenRecordHost
#   然后发 {"cmd":"check-permission"}(见 TROUBLESHOOTING §1.0 的 python 片段)

# 4. 读 TCC.db(需 Full Disk Access;读不到也不影响判断)
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value FROM access WHERE client LIKE '%screenrecord%';"
```

### 根因
**ad-hoc 签名的 CDHash 每次构建都变,系统设置里的旧授权绑定的是失效 CDHash。**
- TCC 对 ad-hoc 二进制按 CDHash 记录授权。用户勾选的开关绑定的是**旧版本二进制的 CDHash**,开关还亮着,但新二进制 CDHash 对不上 → 系统底层判定"拒绝"。
- 本机实际签名是 `Signature=adhoc`(install.sh 的固定证书签名流程一直静默失败,回退到 ad-hoc,见 D-003)。
- 证据:同一台机器上 v0.3.1 时录屏/截图正常(磁盘有 MP4 + 截图作证),装 v0.3.2 后立刻报 TCC denied——唯一改变的就是二进制 + 重签产生的新 CDHash。

### 修复
1. **立即解封**:对当前已安装二进制重置 TCC + 重新授权(绑定当前 CDHash):
   ```bash
   tccutil reset ScreenCapture com.screenrecord.host
   tccutil reset Microphone com.screenrecord.host
   tccutil reset Camera com.screenrecord.host
   # 然后到系统设置重新勾选(关掉再打开,或「+」添加)
   ```
   ⚠️ 临时手段:下次重装 CDHash 又变又会失效。
2. **根治**:修好 install.sh 固定签名流程(见 D-003),让 CDHash 跨重装稳定。

### 寻源关键词
`TCC denied` · `用户拒绝了TCC` · `permission denied 但已勾选` · `CDHash 变化` · `adhoc 签名` · `SCShareableContent failed` · `重装后权限失效`

---

<a id="d-002"></a>
## D-002 摄像头录制报 `startRunning threw exception`(2026-08-07)

### 现象
- 录屏/截图已修好(屏幕录制权限生效),勾选「同时录制摄像头」点开始录制,报:
  ```
  Error: camera start failed: startRunning exception: 
  NSGenericException: *** -[AVCaptureSession startRunning] startRunning may not be 
  called between calls to beginConfiguration and commitConfiguration
  ```
- 宿主日志:`camera: startRunning threw ObjC exception: NSGenericException: ...`

### 关键排查命令
```bash
# 看摄像头相关日志(异常描述已写入日志,这是 D-002 能定位的前提)
grep -i "camera" ~/Library/Logs/ScreenRecordHost.log | tail -20
```

### 根因
**`startRunning()` 在 `beginConfiguration()/commitConfiguration()` 之间被调用**——AVFoundation 的硬性禁止。
- `CameraCapture.start()` 原用 `defer { session.commitConfiguration() }`,但 `defer` 在函数末尾(rollbackIO/startRunning 之后)才执行。
- `startRunning()` 落在 configuration block 内 → 抛 `NSGenericException`。
- 这是纯调用顺序 bug,与权限/硬件/竞态无关。

> 注:这个根因之所以能被发现,是因为 D-004 阶段增强了 `CameraSessionBridge`,把 ObjC 异常的 `name + reason` 写进了 HostLog(之前只打 "threw exception" 没有详情,见 D-003/D-004 的诊断增强)。

### 修复
`CameraCapture.start()` 拆成两阶段(`host/Sources/ScreenRecordHost/CameraCapture.swift`):
1. **配置阶段**:`beginConfiguration` → 添加 input/output(失败在 commit 前回滚)→ **显式 `commitConfiguration()`**
2. **启动阶段**:`commitConfiguration()` **之后**才调 `startRunning()`

用 `do/catch` 而非 `defer` 管理 commit 时机:defer 会在 startRunning 之后才 commit,正好触发该铁律。

### 寻源关键词
`startRunning may not be called between beginConfiguration` · `NSGenericException` · `摄像头 startRunning 异常` · `AVCaptureSession 配置事务` · `defer commitConfiguration 顺序`

---

<a id="d-003"></a>
## D-003 install.sh 固定签名静默失败——从未真正成功过(2026-08-07)

### 现象
- install.sh 注释声称「固定自签证书签名后授权一次永久有效」,但实际签名一直是 ad-hoc。
- 所有签名失败的错误被 `2>/dev/null` 吞掉,静默回退 `codesign --sign -`(ad-hoc)。
- 用户表现为 D-001(勾选了权限却不能用)。

### 关键排查命令(逐步去掉静默,定位真实失败点)
```bash
# 1. 证书材料是否存在 + 格式
openssl x509 -in ~/.config/screenrecord-host/signing-cert.pem -noout -subject -ext basicConstraints,extendedKeyUsage
#   CA:TRUE 是错的!codesigning 身份需要 CA:FALSE 叶子证书

# 2. 临时钥匙串里能否看到 codesigning 身份(关键诊断)
TMPKC=...; security find-identity -p codesigning -v "$TMPKC"
#   返回 "0 valid identities found" = 身份没建立成功

# 3. 实际 codesign 报什么(去掉 2>/dev/null)
codesign --keychain "$TMPKC" --force --sign "ScreenRecordHost Signing" "$APP"
```

### 根因(四个独立 bug,全被 `2>/dev/null` 掩盖)
1. **私钥裸 PEM 导入失败**:`security import -f pemseq -t priv` 对 OpenSSL3/LibreSSL 生成的 `-----BEGIN PRIVATE KEY-----` 报 `Unknown format in import`。私钥根本没进 keychain → 无法配对成身份。
2. **临时 keychain 不在搜索列表**:`codesign` 只查搜索列表中的 keychain,不查 `--keychain` 指定的孤立 keychain。即便导入成功也报 `no identity found`。
3. **证书是 `CA:TRUE`**:自签 CA 证书不被当作合法 codesigning 叶子身份。正确做法是 `CA:FALSE` + `codeSigning` EKU。
4. **`pipefail` + `grep -q` 的 SIGPIPE 误报**:`codesign -dv | grep -q "Authority=..."` 中,grep 匹配后退出关闭管道,codesign 还在写 → SIGPIPE → 退出码 141 → `pipefail` 让整条 `&&` 链判 false → 签名明明成功却误判失败。
   - 这是后来修代码时才发现的:逻辑全对、手动跑成功,但 `bash installer/install.sh` 一直失败,最终定位到管道的 SIGPIPE。

### 修复(`installer/install.sh` 签名段重写)
1. 证书改为**叶子证书**:`basicConstraints=critical,CA:FALSE` + `extendedKeyUsage=critical,codeSigning`。
2. 用 **legacy PKCS#12 一次性导入**(`openssl pkcs12 -export -legacy` 出 3DES p12):解决身份配对 + macOS 对 AES p12 的 `MAC verification failed`。
3. **把临时 keychain 加入搜索列表**:`security list-keychains -d user -s "$TMPKC" "${ORIG_SEARCH[@]}"`。
4. **用数组保存 + cleanup 钩子恢复搜索列表**:修复旧版字符串拼接导致的转义 bug(会把用户搜索列表污染成嵌套路径)。
5. 修掉 SIGPIPE 误报:改用临时文件验证(`codesign -dv > tmpfile 2>&1; grep -q Authority tmpfile`),生产者写完即正常退出。
6. **去掉所有 `2>/dev/null` 吞错**:签名失败时**明确 `exit 1` 中止 + 给出可操作指引**(清证书重生成 / 升级 openssl),不再静默回退 ad-hoc。

### 验证
```bash
# 重装两次,CDHash 应完全一致(证明固定签名生效)
bash installer/install.sh && codesign -d --verbose=4 ~/Applications/ScreenRecordHost.app 2>&1 | grep CDHash
bash installer/install.sh && codesign -d --verbose=4 ~/Applications/ScreenRecordHost.app 2>&1 | grep CDHash
# 两次 CDHash 相同 = 授权一次永久有效

# 确认非 ad-hoc
codesign -dv ~/Applications/ScreenRecordHost.app 2>&1 | grep -i authority
# 应输出:Authority=ScreenRecordHost Signing
```

### 寻源关键词
`Unknown format in import` · `MAC verification failed PKCS12` · `no identity found codesign` · `0 valid identities found` · `adhoc 回退` · `pipefail SIGPIPE grep -q` · `codesign 临时钥匙串` · `自签证书 CA:TRUE` · `list-keychains 搜索列表污染`

---

<a id="d-004"></a>
## D-004 摄像头 `startRunning` 异步竞态(中间态诊断,最终根因见 D-002)

### 现象(当时的判断)
- 摄像头报 `session failed to run (startRunning threw or returned not-running)`。
- 日志 `camera auth=0`(notDetermined)→ `camera: session failed to run`。

### 当时的假设与修复(部分正确)
- 假设:`startRunning()` 返回后 `session.isRunning` 往往还是 false(硬件后台初始化),同步检查 `isRunning` 误判失败。
- 修复:改用 `NotificationCenter` 观察 `AVCaptureSession.didStartRunningNotification`,配 `runtimeError`/`didStopRunning` + 10s 超时。

### 为何标记为「中间态」
- 这个修复**增强了诊断能力**(把 ObjC 异常的 name+reason 写进日志),从而暴露了 D-002 的真实根因:`NSGenericException: startRunning may not be called between beginConfiguration and commitConfiguration`。
- 即:真正的 bug 是 D-002 的调用顺序问题,而非 isRunning 的异步延迟。D-004 的通知观察机制保留(作为正确的成功判定方式),但若没修 D-002,startRunning 根本到不了「等待通知」那一步就会抛异常。

### 保留的价值
- `CameraSessionBridge` 改为返回 `NSString*`(异常描述)而非 `bool`:让 ObjC 异常**可诊断**(写进 HostLog),不再只有 "threw exception"。
- `waitForSessionRunning` 通知观察:正确的成功判定,取代同步轮询 `isRunning`。

### 寻源关键词
`isRunning false after startRunning` · `didStartRunningNotification` · `ObjC 异常不可见` · `CameraSessionBridge` · `摄像头诊断日志`

---

## 维护指引

### 新增记录的格式
```markdown
<a id="d-XXX"></a>
## D-XXX 简短标题(日期)
### 现象        # 用户看到/日志里的具体表现
### 关键排查命令  # 能复现/定位问题的具体命令
### 根因        # 为什么会这样(机制层面)
### 修复        # 改了哪个文件、怎么改的
### 寻源关键词   # 用 grep 能命中的关键词,供未来搜索
```

### 何时登记
- 同类问题预计会再次卡住超过 10 分钟
- 根因非显而易见(踩坑、API 怪癖、平台特性)
- 排查依赖特定的诊断命令或日志位置

### 不要登记
- 普通业务 bug、拼写错误、明显的逻辑错误
- 已在 TROUBLESHOOTING.md 充分说明的用户侧问题
