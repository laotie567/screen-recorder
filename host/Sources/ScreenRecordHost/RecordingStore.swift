import AppKit
import Foundation

/// 录制文件管理:扫描输出目录、在 Finder 中显示
enum RecordingStore {
    /// 列出输出目录中的录制文件,按修改时间倒序
    static func listRecordings() -> [[String: Any]] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: AppInfo.outputDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "mp4" }
            .compactMap { url -> [String: Any]? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize else { return nil }
                let modified = values.contentModificationDate ?? Date.distantPast
                return [
                    "file": url.lastPathComponent,
                    "path": url.path,
                    "size": size,
                    "modified": modified.timeIntervalSince1970,
                ]
            }
            .sorted { ($0["modified"] as? Double ?? 0) > ($1["modified"] as? Double ?? 0) }
    }

    /// 在 Finder 中显示指定路径
    static func reveal(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}
