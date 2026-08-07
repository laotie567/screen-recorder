import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Metal
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
        case .permissionDenied:
            return "screen recording permission denied — 请先在 系统设置→隐私与安全性→屏幕录制 勾选 ScreenRecordHost,然后回到这里再点一次「开始录制」(宿主会自动重启并生效)"
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
    /// 启动进行中标志:start() 全程可达数十秒(权限/采集),防止期间二次 start 泄漏 stream
    private var isStarting = false

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
        let cameraActive: Bool
    }
    var stateSnapshot: StateSnapshot {
        withState {
            StateSnapshot(
                isRecording: isRecording,
                recordingSince: recordingSince,
                currentFileURL: currentFileURL,
                cameraActive: isRecording && cameraEnabled
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

    // 摄像头:开启时显示圆形悬浮窗(CameraOverlayPanel)。
    // 旧版用 CIContext 合成摄像头到屏幕帧;现改为原生浮窗 + AVCaptureVideoPreviewLayer,
    // ScreenCaptureKit 的 excludingWindows:[] 会自然捕获浮窗,所见即所得,无需合成。
    private(set) var cameraEnabled = false

    private override init() { super.init() }

    // MARK: - 开始

    func start(camera: Bool = false) async throws {
        // starting 标志防并发二次启动(权限/采集流程可达数十秒)
        let canStart = withState { () -> Bool in
            guard !isRecording, !isStarting else { return false }
            isStarting = true
            return true
        }
        guard canStart else { throw RecorderError.alreadyRecording }
        defer { withState { self.isStarting = false } }

        // SCShareableContent 在权限异常时可能长时间不返回(SCK 已知怪癖)。
        // 未授权时首次调用 SCShareableContent 本身会触发系统 TCC 授权弹窗(官方路径)。
        // 用户允许后 macOS 可能直接重启本进程:此时本次调用会失败/超时,
        // 下次再点「开始录制」即由 Chrome 拉起新进程,授权立即生效。
        let contentSem = DispatchSemaphore(value: 0)
        var contentResult: Result<SCShareableContent, Error>?
        // 注意:Task 捕获非 Sendable 变量,依赖信号量内存序同步(swift-tools 5.10 宽松并发下合法;
        // 升级 Swift 6 严格并发需改为 actor/锁)
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
            HostLog.write("recorder: SCShareableContent TIMED OUT after 15s")
            throw RecorderError.setupFailed("SCShareableContent timed out (screen recording permission may need restart)")
        }
        let content: SCShareableContent
        switch contentResult {
        case .success(let c):
            HostLog.write("recorder: SCShareableContent ok, displays=\(c.displays.count)")
            content = c
        case .failure(let e):
            // 内容获取失败:未授权时归为权限问题(并引导授权后重试)
            HostLog.write("recorder: SCShareableContent failed: \(e.localizedDescription)")
            if !CGPreflightScreenCaptureAccess() {
                throw RecorderError.permissionDenied
            }
            throw RecorderError.setupFailed("SCShareableContent: \(e.localizedDescription)")
        case nil:
            throw RecorderError.setupFailed("SCShareableContent failed")
        }
        guard !content.displays.isEmpty else {
            if !CGPreflightScreenCaptureAccess() {
                throw RecorderError.permissionDenied
            }
            throw RecorderError.setupFailed("no display found")
        }
        let mainID = CGMainDisplayID()

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

        // 摄像头(可选):权限拒绝/无设备时明确报错,不静默降级——用户勾选了就是要录到
        if camera {
            HostLog.write("recorder: camera auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
            try await CameraCapture.ensurePermission()
            try CameraCapture.shared.start()
            // 摄像头 session 启动后,显示圆形浮窗(所见即所得:浮窗会被屏幕录制捕获)。
            // 必须在 session.startRunning() 成功之后,否则预览层无画面。
            CameraOverlayPanel.shared.show(previewSession: CameraCapture.shared.session)
            HostLog.write("recorder: camera started + overlay shown")
        }
        // 摄像头启动后的所有失败出口统一回收(幂等,do/catch 兜底)
        do {
            try startPipeline(camera: camera, mainID: mainID, content: content)
        } catch {
            stopCameraIfNeeded()
            throw error
        }
    }

    /// 采集管线:写盘 → SCStream → startCapture;成功后状态移交实例字段。
    /// 仅被 start(camera:) 调用,异常由调用方回收摄像头。
    private func startPipeline(camera: Bool, mainID: CGDirectDisplayID, content: SCShareableContent) throws {
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
            throw RecorderError.setupFailed("no display found")
        }

        // 输出分辨率必须用物理像素,而不是逻辑点。
        // ⚠️ 不要用 CGDisplayPixelsWide/High:在 Retina 屏上它们返回的是【逻辑点】(如 1512),
        //    不是物理像素(3024)→ 录制只有 1/4 面积,清晰度严重不足(实测 1512×982 而非 3024×1964)。
        // 正确做法:CGDisplayCopyDisplayMode().pixelWidth/Height 返回真实物理像素。
        //    (SCDisplay 无 pixel 属性,需经 displayID 取 CGDisplayMode。)
        let pixelWidth: Int
        let pixelHeight: Int
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            pixelWidth = Int(mode.pixelWidth)
            pixelHeight = Int(mode.pixelHeight)
        } else {
            // 兜底:极端情况下取不到 mode 时退回逻辑点(清晰度降级,但不致录制失败)
            pixelWidth = Int(CGDisplayPixelsWide(display.displayID))
            pixelHeight = Int(CGDisplayPixelsHigh(display.displayID))
        }
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
        let (writer, videoIn, audioIn): (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput)
        do {
            (writer, videoIn, audioIn) = try makeWriter(outputURL: url, width: pixelWidth, height: pixelHeight, fps: frameRate)
        } catch {
            try? FileManager.default.removeItem(at: url) // 清理 0 字节文件
            throw error
        }

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
            HostLog.write("recorder: startCapture TIMED OUT after 20s")
            stream.stopCapture { _ in }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url) // 清理 0 字节文件
            throw RecorderError.setupFailed("startCapture timed out (screen recording permission may need restart)")
        }
        if let captureError {
            HostLog.write("recorder: startCapture error: \(captureError.localizedDescription)")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.setupFailed("startCapture: \(captureError.localizedDescription)")
        }
        HostLog.write("recorder: capture started \(pixelWidth)x\(pixelHeight)@\(frameRate) camera=\(camera)")

        withState {
            self.stream = stream
            self.writer = writer
            self.videoInput = videoIn
            self.audioInput = audioIn
            self.cameraEnabled = camera
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

        notifyStatus("recording-started", ["file": url.lastPathComponent, "camera": cameraEnabled])
    }

    /// 摄像头回收(幂等):录制开始失败/正常停止/异常终止的所有出口都必须走这里
    private func stopCameraIfNeeded() {
        withState {
            cameraEnabled = false
        }
        CameraOverlayPanel.shared.hide()
        CameraCapture.shared.stop()
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
        stopCameraIfNeeded()

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
        stopCameraIfNeeded()
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

        // 摄像头不再合成进屏幕帧:改用原生悬浮窗 + AVCaptureVideoPreviewLayer,
        // ScreenCaptureKit 自然捕获浮窗(所见即所得)。故无 camera 分支,sampleBuffer 直写。

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
            // 摄像头以原生悬浮窗显示(所见即所得),屏幕帧 sampleBuffer 直写零拷贝。
            // 不再 CIContext 合成,故无 camera 分支。
            // 帧率:SCK 按 minimumFrameInterval(1/60s)交付,内容静止时自动降帧(省电),
            // 这是正常行为(VFR 可变帧率)。不做 PTS 节流——实测节流会把 ~30fps 进一步砍低。
            // 容器标称帧率由 AVAssetWriter 的 AVVideoExpectedSourceFrameRateKey 声明。
            let videoInput = withState { self.videoInput }
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            videoInput.append(sampleBuffer)
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
        stopCameraIfNeeded()
        notifyStatus("recording-failed", ["error": error.localizedDescription])
    }
}
