import AppKit
import Foundation

/// 菜单栏控制器:空闲显示普通图标,录制中显示红点,菜单提供停止录制/打开目录/退出。
/// 浏览器最小化甚至退出 Chrome 后,用户靠它停止录制。
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLabel = NSMenuItem(title: "未在录制", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "停止录制", action: #selector(stopRecording), keyEquivalent: "")

    private override init() {
        super.init()
    }

    func setup() {
        statusItem.button?.image = Self.makeIcon(recording: false)
        statusItem.button?.toolTip = "录屏批注助手"

        stopItem.target = self
        stopItem.isEnabled = false

        let openItem = NSMenuItem(title: "打开录制目录", action: #selector(openOutputDirectory), keyEquivalent: "")
        openItem.target = self
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        let menu = NSMenu()
        menu.addItem(statusLabel)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        updateUI(recording: Recorder.shared.stateSnapshot.isRecording)

        // 订阅录制状态变化(主线程更新 UI)
        NotificationCenter.default.addObserver(
            forName: Recorder.statusChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let event = note.userInfo?["event"] as? String
            self.updateUI(recording: event == "recording-started")
        }
    }

    // MARK: - UI

    private func updateUI(recording: Bool) {
        statusItem.button?.image = Self.makeIcon(recording: recording)
        if recording {
            statusLabel.title = "正在录制…(点「停止录制」结束)"
            stopItem.isEnabled = true
        } else {
            statusLabel.title = "未在录制"
            stopItem.isEnabled = false
        }
    }

    private static func makeIcon(recording: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        if recording {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10)).fill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
        }
        image.unlockFocus()
        return image
    }

    // MARK: - 动作

    @objc private func stopRecording() {
        do {
            let result = try Recorder.shared.stop()
            statusLabel.title = "已停止:\(result.file)"
        } catch {
            statusLabel.title = "停止失败:\(error.localizedDescription)"
        }
    }

    @objc private func openOutputDirectory() {
        NSWorkspace.shared.open(AppInfo.outputDirectory)
    }

    @objc private func quit() {
        // 录制中退出:先停止,等 recording-stopped(文件已落盘)再退出,定时器仅兜底
        if Recorder.shared.stateSnapshot.isRecording {
            _ = try? Recorder.shared.stop()
            var done = false
            NotificationCenter.default.addObserver(
                forName: Recorder.statusChanged, object: nil, queue: .main
            ) { _ in
                if !done && !Recorder.shared.stateSnapshot.isRecording {
                    done = true
                    NSApp.terminate(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                if !done {
                    done = true
                    NSApp.terminate(nil)
                }
            }
        } else {
            NSApp.terminate(nil)
        }
    }
}
