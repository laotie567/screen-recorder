import AppKit
import Darwin
import Foundation

// 屏幕内容敏感:进程级 umask 077,所有新建文件默认 0600、目录 0700,
// 消除录制中 MP4 的权限窗口期(显式 chmod 600 作为兜底保留)
umask(0o077)

// MARK: - 入口

// 环境变量 SCREENRECORDHOST_NO_APPKIT=1 时进入无 UI 模式:
// 只跑 stdin 消息循环,EOF 即退出。用于协议测试/无头调试。
// 录制中 EOF 时等待录制结束(避免测试/无头录制截断文件)。
if ProcessInfo.processInfo.environment["SCREENRECORDHOST_NO_APPKIT"] == "1" {
    runMessageLoop()
    if Recorder.shared.stateSnapshot.isRecording {
        NotificationCenter.default.addObserver(
            forName: Recorder.statusChanged, object: nil, queue: nil
        ) { _ in
            if !Recorder.shared.stateSnapshot.isRecording {
                exit(0)
            }
        }
        RunLoop.main.run() // 阻塞等待录制结束,不落到下方 AppKit 初始化
    } else {
        exit(0)
    }
}

// 正常模式:无窗口菜单栏 app。
// NSApplication 事件循环必须跑在主线程(NSStatusItem 依赖它);
// native messaging 的 stdin 读取放在后台线程。
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 无 Dock 图标

// MARK: - 单实例锁 + 优雅退出(防「孤儿录制」产生损坏 MP4,DEBUG_LOG D-010)
//
// 背景:录制中 Chrome 侧 service worker 被杀 → native messaging 断连(stdin EOF)→
// 录制继续但扩展已失联(孤儿录制)。用户此时点「开始录制」会拉起第二个实例,
// 旧实例的录制永远收不到停止命令;旧实例最终被外部杀死时 finishWriting 没跑 →
// MP4 缺 moov atom → 文件打不开(2.5GB 录制丢失的实际案例)。
//
// 防护:
// 1. 单实例锁(锁文件存 pid):新实例启动时若发现旧实例存活,发 SIGTERM 让其
//    优雅收尾(安全停止+finishWriting+保存)后再接管。
// 2. SIGTERM/SIGINT 处理:任何外部终止信号都走优雅退出,保住录制文件。

let hostLockPath = NSTemporaryDirectory() + "com.screenrecord.host.pid"

/// 优雅退出:录制中则安全停止(等 finishWriting 落盘)再退出。
/// 必须在主线程调用(等 finishWriting 用主 RunLoop 轮询)。
func gracefulShutdown() {
    guard Recorder.shared.stateSnapshot.isRecording else {
        HostLog.write("host: graceful shutdown (not recording)")
        exit(0)
    }
    HostLog.write("host: graceful shutdown, stopping recording to finalize MP4…")
    _ = try? Recorder.shared.stop()
    // 等 finishWriting 完成(最长 15s:4K 长视频封装需要时间),超时也退出(尽力而为)
    let deadline = Date().addingTimeInterval(15)
    while Recorder.shared.stateSnapshot.isRecording && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    HostLog.write("host: recording finalized, exiting")
    exit(0)
}

// 单实例接管:锁文件里有活着的旧实例 → SIGTERM 让它优雅收尾,等它退出再继续
if let data = FileManager.default.contents(atPath: hostLockPath),
   let str = String(data: data, encoding: .utf8),
   let oldPid = Int32(str.trimmingCharacters(in: .whitespacesAndNewlines)),
   oldPid != ProcessInfo.processInfo.processIdentifier,
   kill(oldPid, 0) == 0 {
    HostLog.write("host: another instance alive (pid=\(oldPid)), requesting graceful takeover…")
    kill(oldPid, SIGTERM)
    var waited = 0.0
    while kill(oldPid, 0) == 0 && waited < 20 {
        Thread.sleep(forTimeInterval: 0.2)
        waited += 0.2
    }
    if kill(oldPid, 0) == 0 {
        HostLog.write("host: old instance did not exit in 20s, continuing anyway")
    }
}
// 写入自己的 pid(残留无害:下次启动按 pid 活性判断)
try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: hostLockPath, atomically: true, encoding: .utf8)

// SIGTERM/SIGINT → 优雅退出(屏蔽默认的立即死亡,否则 finishWriting 没机会跑)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { gracefulShutdown() }
termSource.resume()
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler { gracefulShutdown() }
intSource.resume()

do {
    try AppInfo.ensureDirectories()
} catch {
    fputs("ScreenRecordHost: failed to create directories: \(error)\n", stderr)
}

// 启动自检:屏幕录制权限(未授权时提示;授权后需重启进程,TCC 要求)
if !CGPreflightScreenCaptureAccess() {
    fputs("ScreenRecordHost: screen recording permission NOT granted. Grant it in 系统设置 → 隐私与安全性 → 屏幕录制, then restart this app.\n", stderr)
}

StatusItemController.shared.setup()
HostLog.write("host started: version=\(AppInfo.version) pid=\(ProcessInfo.processInfo.processIdentifier)")

// 后台消息循环线程
DispatchQueue.global(qos: .userInitiated).async {
    runMessageLoop()
    HostLog.write("stdin EOF (Chrome disconnected)")
    // stdin EOF(Chrome 断开)。非录制时立即退出;录制中保持到录制结束再退出,
    // 避免 Chrome 重连时拉起第二个宿主实例(双菜单栏图标)。
    // 连录的稳定性由 service worker 的重连逻辑保证(见 service-worker.js onDisconnect)。
    let terminate = {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    if Recorder.shared.stateSnapshot.isRecording {
        NotificationCenter.default.addObserver(
            forName: Recorder.statusChanged, object: nil, queue: nil
        ) { _ in
            if !Recorder.shared.stateSnapshot.isRecording {
                terminate()
            }
        }
    } else {
        terminate()
    }
}

app.run()

// MARK: - 消息循环

private func runMessageLoop() {
    CommandHandler.setup()
    while let message = NativeMessaging.readMessage() {
        CommandHandler.handle(message)
    }
}
