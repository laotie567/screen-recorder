import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import Foundation

enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case permissionDenied
    case micPermissionDenied
    case setupFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "already recording"
        case .notRecording: return "not recording"
        case .permissionDenied: return "screen recording permission denied"
        case .micPermissionDenied: return "microphone permission denied"
        case .setupFailed(let msg): return "setup failed: \(msg)"
        case .writeFailed(let msg): return "write failed: \(msg)"
        }
    }
}

/// 录屏核心:ScreenCaptureKit 采集主屏全屏 + 系统音频,AVAssetWriter 输出 MP4(H.264+AAC,60fps)。
/// 麦克风混合在第 4 步接入(届时系统音频改走 AudioMixer)。
final class Recorder: NSObject {
    static let shared = Recorder()

    private(set) var isRecording = false
    private(set) var recordingSince: Date?
    private(set) var currentFileURL: URL?

    /// 状态锁:保护状态字段跨线程访问(消息循环线程 / 采样线程 / SCK 回调)
    private let stateLock = NSLock()

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    /// 线程安全状态快照(供外部查询,避免无锁读)
    struct StateSnapshot {
        let isRecording: Bool
        let recordingSince: Date?
        let currentFileURL: URL?
    }
    var stateSnapshot: StateSnapshot {
        withState {
            StateSnapshot(
                isRecording: isRecording,
                recordingSince: recordingSince,
                currentFileURL: currentFileURL
            )
        }
    }

    static let statusChanged = Notification.Name("com.screenrecord.recorder.statusChanged")

    /// 状态变化通知(录制开始/结束/失败),由 CommandHandler 与菜单栏 UI 订阅
    private func notifyStatus(_ event: String, _ payload: [String: Any]) {
        var userInfo: [String: Any] = ["event": event]
        for (key, value) in payload {
            userInfo[key] = value
        }
        NotificationCenter.default.post(
            name: Recorder.statusChanged,
            object: self,
            userInfo: userInfo
        )
    }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStartTime: CMTime?
    private let mixer = AudioMixer()
    private let processingQueue = DispatchQueue(label: "com.screenrecord.recorder.processing")

    private override init() { super.init() }

    // MARK: - 开始

    func start() async throws {
        guard !withState({ isRecording }) else { throw RecorderError.alreadyRecording }

        // 屏幕录制权限:未授权时先触发系统授权弹窗。
        // 注意:只有真正调用录制 API 才会弹窗(CGPreflightScreenCaptureAccess 仅查询)。
        // CGWindowListCreateImage 在 macOS 15 起不可用,改用 AVCaptureScreenInput
        // (仍可用且未授权时会触发 TCC 弹窗;已拒绝时不会重复弹窗)。
        if !CGPreflightScreenCaptureAccess() {
            await triggerScreenPermissionPrompt()
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw RecorderError.permissionDenied
        }

        // 麦克风权限:未决时弹系统授权窗,拒绝则明确报错
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError.micPermissionDenied
            }
        default:
            throw RecorderError.micPermissionDenied
        }

        // SCShareableContent 在权限异常时可能长时间不返回(SCK 已知怪癖)。
        // 与 startCapture 一致用信号量 + 超时保护(不依赖任务取消,TG 取消不可靠)
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
            throw RecorderError.setupFailed("SCShareableContent timed out (screen recording permission may need restart)")
        }
        let content: SCShareableContent
        switch contentResult {
        case .success(let c): content = c
        case .failure(let e): throw RecorderError.setupFailed("SCShareableContent: \(e.localizedDescription)")
        case nil: throw RecorderError.setupFailed("SCShareableContent failed")
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
            throw RecorderError.setupFailed("no display found")
        }

        // 输出分辨率必须用物理像素,而不是逻辑点(width/height):
        // Retina 屏逻辑 1728×1117 的物理像素是 3456×2234,用逻辑点录制只有 1/4 面积,视频会模糊
        // SCDisplay 无 pixel 属性,用 CGDisplayPixelsWide/High 按 displayID 取物理像素(未废弃 API)
        let pixelWidth = Int(CGDisplayPixelsWide(display.displayID))
        let pixelHeight = Int(CGDisplayPixelsHigh(display.displayID))
        let frameRate = 60 // 60fps(剪映等剪辑软件原生支持;码率已按 60fps 提高 50%)

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate)) // 60fps
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true // 麦克风采集(macOS 15+ 原生支持)

        let url = try nextOutputURL()
        let (writer, videoIn, audioIn) = try makeWriter(outputURL: url, width: pixelWidth, height: pixelHeight, fps: frameRate)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: processingQueue)

        // startCapture 的 completion 在权限异常时可能不回调(SCK 已知怪癖),
        // 用信号量 + 超时保护,避免宿主无限挂起导致 popup "host timeout"
        let captureSem = DispatchSemaphore(value: 0)
        var captureError: Error?
        stream.startCapture { error in
            captureError = error
            captureSem.signal()
        }
        let waitResult = captureSem.wait(timeout: .now() + 20)
        if waitResult == .timedOut {
            stream.stopCapture { _ in }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url) // 清理 0 字节文件
            throw RecorderError.setupFailed("startCapture timed out (screen recording permission may need restart)")
        }
        if let captureError {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.setupFailed("startCapture: \(captureError.localizedDescription)")
        }

        withState {
            self.stream = stream
            self.writer = writer
            self.videoInput = videoIn
            self.audioInput = audioIn
            self.sessionStartTime = nil
            self.currentFileURL = url
            self.isRecording = true
            self.recordingSince = Date()
        }

        // 混音输出 → 写音轨
        mixer.onOutput = { [weak self] sampleBuffer in
            guard let self else { return }
            let (writer, audioInput) = self.withState { (self.writer, self.audioInput) }
            guard let writer, writer.status == .writing,
                  let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }

        notifyStatus("recording-started", ["file": url.lastPathComponent])
    }

    /// 触发屏幕录制 TCC 授权弹窗:启动一个 AVCaptureScreenInput 会话,
    /// 轮询等待用户响应(最多 15 秒),然后停止会话。
    /// 注意:屏幕录制授权变更后,TCC 通常要求重启进程才完全生效,
    /// 授权后首次录制若仍失败,popup 会引导重启宿主。
    private func triggerScreenPermissionPrompt() async {
        let session = AVCaptureSession()
        guard let input = AVCaptureScreenInput(displayID: CGMainDisplayID()),
              session.canAddInput(input) else { return }
        session.addInput(input)
        session.startRunning()
        defer { session.stopRunning() }
        for _ in 0..<150 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms × 150 = 15s
            if CGPreflightScreenCaptureAccess() { return }
        }
    }

    // MARK: - 停止

    struct StopResult {
        let file: String
        let duration: Double
    }

    func stop() throws -> StopResult {
        let (stream, writer, url, startedAt) = try withState { () -> (SCStream?, AVAssetWriter?, URL?, Date) in
            guard isRecording else { throw RecorderError.notRecording }
            let tuple = (self.stream, self.writer, currentFileURL, recordingSince ?? Date())
            isRecording = false
            return tuple
        }
        guard let stream, let writer else { throw RecorderError.notRecording }

        stream.stopCapture { _ in }

        processingQueue.async { [weak self] in
            guard let self else { return }
            writer.finishWriting { [weak self] in
                guard let self else { return }
                // 竞态保护:如果停止后用户已开始新录制(currentFileURL 已变),旧回调不得清理新状态
                let current = self.withState { self.currentFileURL }
                guard current == url else { return }
                let duration = Date().timeIntervalSince(startedAt)
                if writer.status == .completed {
                    // 屏幕内容敏感:显式 0600
                    if let url {
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o600], ofItemAtPath: url.path
                        )
                    }
                    self.withState {
                        self.currentFileURL = nil
                        self.recordingSince = nil
                    }
                    self.notifyStatus("recording-stopped", [
                        "file": url?.lastPathComponent ?? "",
                        "duration": duration,
                    ])
                } else {
                    self.withState {
                        self.currentFileURL = nil
                        self.recordingSince = nil
                    }
                    self.notifyStatus("recording-failed", [
                        "file": url?.lastPathComponent ?? "",
                        "error": writer.error?.localizedDescription ?? "unknown",
                    ])
                }
            }
        }

        return StopResult(file: url?.lastPathComponent ?? "", duration: Date().timeIntervalSince(startedAt))
    }

    private func failWriter(_ writer: AVAssetWriter) {
        // 锁内更新状态(幂等:仅首次 isRecording=true 时执行),锁外通知
        let (url, stream) = withState { () -> (URL?, SCStream?) in
            guard isRecording else { return (nil, nil) }
            isRecording = false
            let u = currentFileURL
            currentFileURL = nil
            recordingSince = nil
            return (u, self.stream)
        }
        guard let url else { return }
        stream?.stopCapture { _ in }
        notifyStatus("recording-failed", [
            "error": writer.error?.localizedDescription ?? "write failed",
            "file": url.lastPathComponent,
        ])
    }

    // MARK: - 输出文件

    private func nextOutputURL() throws -> URL {
        try AppInfo.ensureDirectories()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "录屏-\(formatter.string(from: Date()))"
        var url = AppInfo.outputDirectory.appendingPathComponent(base).appendingPathExtension("mp4")
        var index = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = AppInfo.outputDirectory
                .appendingPathComponent("\(base)-\(index)")
                .appendingPathExtension("mp4")
            index += 1
        }
        return url
    }

    /// 按输出像素高度与帧率选择 H.264 平均码率。
    /// 60fps 帧数是 30fps 的两倍,码率提高 50%(编码器可高效利用冗余帧,无需翻倍)。
    static func bitrate(forPixelHeight height: Int, fps: Int) -> Int {
        let base: Int
        switch height {
        case 2160...: base = 24_000_000  // 4K@30
        case 1440...: base = 16_000_000  // 2K@30
        case 1080...: base = 12_000_000  // FHD@30
        default: base = 8_000_000        // 720p 及以下
        }
        return fps >= 60 ? base * 3 / 2 : base
    }

    private func makeWriter(outputURL url: URL, width: Int, height: Int, fps: Int) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Recorder.bitrate(forPixelHeight: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioIn.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoIn), writer.canAdd(audioIn) else {
            throw RecorderError.setupFailed("cannot add inputs")
        }
        writer.add(videoIn)
        writer.add(audioIn)

        guard writer.startWriting() else {
            throw RecorderError.setupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        return (writer, videoIn, audioIn)
    }
}

// MARK: - SCStreamOutput

extension Recorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let (writer, isRec) = withState { (self.writer, self.isRecording) }
        guard let writer else { return }
        // writer 进入 failed(磁盘满/编码失败):主动停止并通知,而不是静默丢帧
        if writer.status == .failed {
            failWriter(writer)
            return
        }
        guard isRec, writer.status == .writing else { return }

        // 单次加锁:检查+赋值原子,保证并发回调下 startSession 恰好一次
        let isFirst = withState { () -> Bool in
            if self.sessionStartTime == nil {
                self.sessionStartTime = sampleBuffer.presentationTimeStamp
                return true
            }
            return false
        }
        if isFirst {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }

        switch type {
        case .screen:
            let videoInput = withState { self.videoInput }
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            mixer.push(sampleBuffer, isMicrophone: false)
        case .microphone:
            mixer.push(sampleBuffer, isMicrophone: true)
        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension Recorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 身份守卫:旧流的错误回调不得污染新录制状态(与 stop 的 finish 回调一致)
        let shouldNotify = withState { () -> Bool in
            guard self.stream === stream else { return false }
            isRecording = false
            recordingSince = nil
            currentFileURL = nil
            return true
        }
        guard shouldNotify else { return }
        notifyStatus("recording-failed", ["error": error.localizedDescription])
    }
}
