import AppKit
import CoreGraphics
import ScreenCaptureKit
import Foundation

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "screen recording permission denied — 请先在 系统设置→隐私与安全性→屏幕录制 勾选 ScreenRecordHost,然后回到这里再点一次「截图」(宿主会自动重启并生效)"
        case .captureFailed(let msg): return "capture failed: \(msg)"
        }
    }
}

/// 截图服务:捕获主屏单帧,输出 PNG 到中转目录,返回文件路径。
/// (全屏 PNG 可能超过 native messaging 1MB 单条上限,所以走文件路径而非 base64)
enum ScreenCaptureService {
    static func captureMainDisplay() async throws -> URL {
        // 与录屏一致的权限流程:先调 SCShareableContent(首次未授权时该调用本身会触发
        // 系统 TCC 授权弹窗,官方路径),失败/空 displays 时才用 CGPreflight 兜底归类为
        // permissionDenied(带"授权后重试"引导)。不要前置 CGPreflight guard,否则弹窗永不触发。
        let contentSem = DispatchSemaphore(value: 0)
        var contentResult: Result<SCShareableContent, Error>?
        // 注意:Task 捕获非 Sendable 变量,依赖信号量内存序同步(swift-tools 5.10 宽松并发下合法)
        Task {
            do {
                let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                contentResult = .success(c)
            } catch {
                contentResult = .failure(error)
            }
            contentSem.signal()
        }
        if contentSem.wait(timeout: .now() + 15) == .timedOut {
            throw ScreenCaptureError.captureFailed("SCShareableContent timed out (screen recording permission may need restart)")
        }
        let content: SCShareableContent
        switch contentResult {
        case .success(let c):
            content = c
        case .failure(let e):
            // 内容获取失败:未授权时归为权限问题(并引导授权后重试)
            if !CGPreflightScreenCaptureAccess() {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.captureFailed("SCShareableContent: \(e.localizedDescription)")
        case nil:
            throw ScreenCaptureError.captureFailed("SCShareableContent failed")
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
            if !CGPreflightScreenCaptureAccess() {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.captureFailed("no display found")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // 与录屏一致:用物理像素,避免 Retina 屏截图模糊(逻辑点只有 1/4 面积)。
        // ⚠️ CGDisplayPixelsWide/High 在 Retina 屏返回逻辑点,必须用 CGDisplayMode.pixelWidth/Height。
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            config.width = Int(mode.pixelWidth)
            config.height = Int(mode.pixelHeight)
        } else {
            config.width = Int(CGDisplayPixelsWide(display.displayID))
            config.height = Int(CGDisplayPixelsHigh(display.displayID))
        }

        // captureImage 的 completion 在权限异常时可能不回调(SCK 已知怪癖),
        // 用信号量 + 超时保护,避免宿主无限挂起
        let captureSem = DispatchSemaphore(value: 0)
        var capturedImage: CGImage?
        var captureError: Error?
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
            capturedImage = image
            captureError = error
            captureSem.signal()
        }
        if captureSem.wait(timeout: .now() + 20) == .timedOut {
            throw ScreenCaptureError.captureFailed("captureImage timed out (screen recording permission may need restart)")
        }
        if let captureError {
            throw ScreenCaptureError.captureFailed(captureError.localizedDescription)
        }
        guard let image = capturedImage else {
            throw ScreenCaptureError.captureFailed("captureImage returned nil")
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.captureFailed("PNG encoding failed")
        }

        try AppInfo.ensureDirectories()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "screenshot-\(formatter.string(from: Date()))"
        var url = AppInfo.supportDirectory.appendingPathComponent(base).appendingPathExtension("png")
        var index = 1
        while FileManager.default.fileExists(atPath: url.path) {
            // 文件名冲突递增,避免同一秒两次截图互相覆盖
            url = AppInfo.supportDirectory
                .appendingPathComponent("\(base)-\(index)")
                .appendingPathExtension("png")
            index += 1
        }
        try pngData.write(to: url)
        // 屏幕内容敏感:显式 0600,防同机其他用户读取
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        return url
    }
}
