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
