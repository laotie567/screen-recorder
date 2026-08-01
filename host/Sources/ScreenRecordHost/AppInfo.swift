import Foundation

/// 全局信息:版本号、输出目录、数据目录
enum AppInfo {
    static let version = "0.1.0"

    /// 录制输出目录:~/Movies/ScreenRecord
    static let outputDirectory: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("ScreenRecord", isDirectory: true)
    }()

    /// 截图中转目录:~/Library/Application Support/ScreenRecordHost
    static var supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ScreenRecordHost", isDirectory: true)
    }()

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
