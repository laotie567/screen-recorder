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

/// 录屏核心:ScreenCaptureKit 采集主屏全屏 + 系统音频,AVAssetWriter 输出 MP4(H.264+AAC,30fps)。
/// 麦克风混合在第 4 步接入(届时系统音频改走 AudioMixer)。
final class Recorder: NSObject {
    static let shared = Recorder()

    private(set) var isRecording = false
    private(set) var recordingSince: Date?
    private(set) var currentFileURL: URL?

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
        guard !isRecording else { throw RecorderError.alreadyRecording }
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

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
            throw RecorderError.setupFailed("no display found")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true // 麦克风采集(macOS 15+ 原生支持)

        let url = try nextOutputURL()
        let (writer, videoIn, audioIn) = try makeWriter(outputURL: url, width: Int(display.width), height: Int(display.height))

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: processingQueue)

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                stream.startCapture { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        } catch {
            writer.cancelWriting()
            throw RecorderError.setupFailed("startCapture: \(error.localizedDescription)")
        }

        self.stream = stream
        self.writer = writer
        self.videoInput = videoIn
        self.audioInput = audioIn
        self.sessionStartTime = nil
        self.currentFileURL = url
        self.isRecording = true
        self.recordingSince = Date()

        // 混音输出 → 写音轨
        mixer.onOutput = { [weak self] sampleBuffer in
            guard let self, let writer = self.writer, writer.status == .writing else { return }
            if let audioInput = self.audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }

        notifyStatus("recording-started", ["file": url.lastPathComponent])
    }

    // MARK: - 停止

    struct StopResult {
        let file: String
        let duration: Double
    }

    func stop() throws -> StopResult {
        guard isRecording, let stream, let writer else { throw RecorderError.notRecording }
        let url = currentFileURL
        let startedAt = recordingSince ?? Date()
        isRecording = false

        stream.stopCapture { _ in }

        processingQueue.async { [weak self] in
            guard let self else { return }
            writer.finishWriting { [weak self] in
                guard let self else { return }
                // 竞态保护:如果停止后用户已开始新录制(currentFileURL 已变),旧回调不得清理新状态
                guard self.currentFileURL == url else { return }
                let duration = Date().timeIntervalSince(startedAt)
                if writer.status == .completed {
                    // 屏幕内容敏感:显式 0600
                    if let url {
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o600], ofItemAtPath: url.path
                        )
                    }
                    self.currentFileURL = nil
                    self.recordingSince = nil
                    self.notifyStatus("recording-stopped", [
                        "file": url?.lastPathComponent ?? "",
                        "duration": duration,
                    ])
                } else {
                    self.currentFileURL = nil
                    self.recordingSince = nil
                    self.notifyStatus("recording-failed", [
                        "file": url?.lastPathComponent ?? "",
                        "error": writer.error?.localizedDescription ?? "unknown",
                    ])
                }
            }
        }

        return StopResult(file: url?.lastPathComponent ?? "", duration: Date().timeIntervalSince(startedAt))
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

    private func makeWriter(outputURL url: URL, width: Int, height: Int) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
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
        guard isRecording, let writer, writer.status == .writing else { return }

        if sessionStartTime == nil {
            sessionStartTime = sampleBuffer.presentationTimeStamp
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }

        switch type {
        case .screen:
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
        guard self.stream === stream else { return }
        isRecording = false
        recordingSince = nil
        currentFileURL = nil
        notifyStatus("recording-failed", ["error": error.localizedDescription])
    }
}
