import AppKit
import Foundation

/// 命令分发。骨架阶段:未实现的业务命令返回明确错误,后续步骤逐个替换。
enum CommandHandler {
    static func setup() {
        // 录制状态变化 → 推送事件给扩展
        NotificationCenter.default.addObserver(
            forName: Recorder.statusChanged, object: nil, queue: nil
        ) { note in
            guard let userInfo = note.userInfo, let event = userInfo["event"] as? String else { return }
            var message: [String: Any] = [:]
            for (key, value) in userInfo {
                if let key = key as? String { message[key] = value }
            }
            message["event"] = event
            NativeMessaging.send(message)
        }
    }

    static func handle(_ message: [String: Any]) {
        // Chrome 握手:MV3 connectNative 建立连接时必答 {"type":"connect"},否则断开
        if let type = message["type"] as? String, type == "connect" {
            NativeMessaging.send(["type": "connect"])
            return
        }

        guard let cmd = message["cmd"] as? String else {
            NativeMessaging.send(["ok": false, "error": "missing cmd field"])
            return
        }

        switch cmd {
        case "ping":
            NativeMessaging.send([
                "ok": true,
                "version": AppInfo.version,
                "pid": ProcessInfo.processInfo.processIdentifier,
            ])

        case "start-record":
            Task {
                do {
                    try await Recorder.shared.start()
                    NativeMessaging.send(["ok": true])
                } catch {
                    NativeMessaging.send(["ok": false, "error": error.localizedDescription])
                }
            }

        case "stop-record":
            do {
                let result = try Recorder.shared.stop()
                NativeMessaging.send([
                    "ok": true,
                    "file": result.file,
                    "duration": result.duration,
                ])
            } catch {
                NativeMessaging.send(["ok": false, "error": error.localizedDescription])
            }

        case "status":
            NativeMessaging.send([
                "ok": true,
                "recording": Recorder.shared.isRecording,
                "recordingSince": Recorder.shared.recordingSince.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "outputDir": AppInfo.outputDirectory.path,
            ])

        case "capture-screen":
            Task {
                do {
                    let url = try await ScreenCaptureService.captureMainDisplay()
                    NativeMessaging.send(["ok": true, "path": url.path])
                } catch {
                    NativeMessaging.send(["ok": false, "error": error.localizedDescription])
                }
            }

        case "list-recordings":
            NativeMessaging.send(["ok": true, "items": RecordingStore.listRecordings()])

        case "reveal-in-finder":
            guard let path = message["path"] as? String else {
                NativeMessaging.send(["ok": false, "error": "missing path field"])
                return
            }
            // 与 read-file 一致:解析 symlink 后校验目录白名单
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let allowed = [AppInfo.outputDirectory.standardizedFileURL.resolvingSymlinksInPath(),
                           AppInfo.supportDirectory.standardizedFileURL.resolvingSymlinksInPath()]
            let isAllowed = allowed.contains { dir in
                url.path == dir.path || url.path.hasPrefix(dir.path + "/")
            }
            guard isAllowed else {
                NativeMessaging.send(["ok": false, "error": "path not allowed"])
                return
            }
            NativeMessaging.send(["ok": RecordingStore.reveal(path: url.path)])

        case "read-file":
            // 分块读取本地文件(base64),供批注页加载截图。仅限宿主自己的两个目录,防路径穿越。
            // 注意:base64 放大 4/3,块大小必须保证编码后 < 1MB(native messaging 上限)
            guard let path = message["path"] as? String,
                  let offset = message["offset"] as? Int, offset >= 0,
                  let size = message["size"] as? Int, size > 0, size <= 750_000 else {
                NativeMessaging.send(["ok": false, "error": "invalid read-file params"])
                return
            }
            // 解析 symlink 后再校验,防目录内符号链接指向外部文件
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let allowed = [AppInfo.supportDirectory.standardizedFileURL.resolvingSymlinksInPath(),
                           AppInfo.outputDirectory.standardizedFileURL.resolvingSymlinksInPath()]
            let isAllowed = allowed.contains { dir in
                url.path == dir.path || url.path.hasPrefix(dir.path + "/")
            }
            guard isAllowed else {
                NativeMessaging.send(["ok": false, "error": "path not allowed"])
                return
            }
            guard let handle = FileHandle(forReadingAtPath: url.path) else {
                NativeMessaging.send(["ok": false, "error": "cannot open file"])
                return
            }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(offset))
            } catch {
                NativeMessaging.send(["ok": false, "error": "seek failed: \(error.localizedDescription)"])
                return
            }
            let data: Data
            do {
                data = try handle.read(upToCount: size) ?? Data()
            } catch {
                NativeMessaging.send(["ok": false, "error": "read failed: \(error.localizedDescription)"])
                return
            }
            NativeMessaging.send([
                "ok": true,
                "data": data.base64EncodedString(),
                "eof": data.count < size,
            ])

        case "test-mixer":
            if let failure = AudioMixer.runSelfTest() {
                NativeMessaging.send(["ok": false, "error": failure])
            } else {
                NativeMessaging.send(["ok": true])
            }

        case "quit":
            NativeMessaging.send(["ok": true])
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }

        default:
            NativeMessaging.send(["ok": false, "error": "unknown command: \(cmd)"])
        }
    }
}
