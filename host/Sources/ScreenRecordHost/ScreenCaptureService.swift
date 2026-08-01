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

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
            throw ScreenCaptureError.captureFailed("no display found")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)

        let image = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: ScreenCaptureError.captureFailed(error?.localizedDescription ?? "captureImage returned nil"))
                }
            }
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
