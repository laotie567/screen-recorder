import AppKit
import CoreGraphics
import ScreenCaptureKit
import Foundation

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "screen recording permission denied"
        case .captureFailed(let msg): return "capture failed: \(msg)"
        }
    }
}

/// 截图服务:捕获主屏单帧,输出 PNG 到中转目录,返回文件路径。
/// (全屏 PNG 可能超过 native messaging 1MB 单条上限,所以走文件路径而非 base64)
enum ScreenCaptureService {
    static func captureMainDisplay() async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        // SCShareableContent 在权限异常时可能长时间不返回(SCK 已知怪癖),加超时保护
        let contentSem = DispatchSemaphore(value: 0)
        var contentResult: Result<SCShareableContent, Error>?
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
        case .success(let c): content = c
        case .failure(let e): throw ScreenCaptureError.captureFailed("SCShareableContent: \(e.localizedDescription)")
        case nil: throw ScreenCaptureError.captureFailed("SCShareableContent failed")
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
            throw ScreenCaptureError.captureFailed("no display found")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // 与录屏一致:用物理像素,避免 Retina 屏截图模糊(逻辑点只有 1/4 面积)
        config.width = Int(CGDisplayPixelsWide(display.displayID))
        config.height = Int(CGDisplayPixelsHigh(display.displayID))

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
        let url = AppInfo.supportDirectory
            .appendingPathComponent("screenshot-\(formatter.string(from: Date()))")
            .appendingPathExtension("png")
        try pngData.write(to: url)
        // 屏幕内容敏感:显式 0600,防同机其他用户读取
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        return url
    }
}
