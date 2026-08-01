import Foundation

/// Chrome Native Messaging 协议:
/// - stdin/stdout 均以 4 字节小端 UInt32 长度前缀 + UTF-8 JSON 传输
/// - 单条消息上限 1MB(Chrome 限制;我们只传命令与文件路径,远小于此)
enum NativeMessaging {
    private static let lock = NSLock()
    static let maxMessageSize = 1_048_576

    /// 从 stdin 读取一条消息;EOF 或格式错误返回 nil
    static func readMessage() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let length = header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self)
        }.littleEndian
        guard length > 0, length < maxMessageSize else { return nil }
        guard let body = readExactly(Int(length)) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// 向 stdout 写入一条消息(线程安全,多线程录制事件推送与命令响应并存)
    static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        // 防超限:Chrome native messaging 单条上限 1MB,超限会断开连接
        guard data.count <= maxMessageSize else {
            fputs("NativeMessaging: message too large (\(data.count) bytes), dropped\n", stderr)
            return
        }
        var length = UInt32(data.count).littleEndian
        lock.lock()
        defer { lock.unlock() }
        withUnsafeBytes(of: &length) { header in
            FileHandle.standardOutput.write(Data(header))
        }
        FileHandle.standardOutput.write(data)
        try? FileHandle.standardOutput.synchronize()
    }

    private static func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: count - data.count), !chunk.isEmpty else {
                return nil // EOF
            }
            data.append(chunk)
        }
        return data
    }
}
