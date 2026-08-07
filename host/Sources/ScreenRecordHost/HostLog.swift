import Foundation

/// 极简文件日志:追加写到 ~/Library/Logs/ScreenRecordHost.log(超 1MB 截断重写)。
/// 动机:Chrome 经 native messaging 拉起宿主后,stderr 不可见,
/// 用户侧的启动/权限/编码失败只能靠这份日志排查。
enum HostLog {
    private static let lock = NSLock()
    private static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/ScreenRecordHost.log")
    }()
    private static let maxBytes = 1_000_000

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = logURL.path
        // 超限时整文件重写(只保最新,避免无限增长)
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
           size > maxBytes {
            try? data.write(to: logURL)
            return
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
