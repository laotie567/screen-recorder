import AVFoundation
import CameraSessionBridge
import CoreVideo
import Foundation

/// 摄像头采集:AVCaptureSession 抓取默认摄像头,只保留最新一帧供画中画合成。
/// 读帧线程安全、不阻塞屏幕采集管线;摄像头帧率独立于屏幕帧率(合成时复用最新帧)。
final class CameraCapture: NSObject {
    enum CameraError: LocalizedError {
        case noDevice
        case permissionDenied
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDevice:
                return "camera requested but no camera device found (未检测到可用摄像头)"
            case .permissionDenied:
                return "camera permission denied — 请在 系统设置→隐私与安全性→摄像头 勾选 ScreenRecordHost,然后再点一次「开始录制」"
            case .startFailed(let msg):
                return "camera start failed: \(msg)"
            }
        }
    }

    static let shared = CameraCapture()

    /// 摄像头采集 session。浮窗预览层(CameraOverlayPanel)共享此 session:
    /// AVCaptureVideoPreviewLayer 与 videoOutput 共存于同一 session 合法(Appple 官方推荐)。
    /// 预览层负责「给人看」,videoOutput 保留供未来取帧需求(本次不再用于合成)。
    private(set) var session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    /// session 配置与启停均在专用串行队列(startRunning 是阻塞调用)
    private let sessionQueue = DispatchQueue(label: "com.screenrecord.camera.session")
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private(set) var isRunning = false

    private override init() { super.init() }

    /// 权限检查:未决时弹系统授权窗;拒绝则明确报错。
    /// 用户显式勾选了「同时录制摄像头」,静默降级会让人误以为录到了摄像头,故直接抛错。
    static func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw CameraError.permissionDenied }
        default:
            throw CameraError.permissionDenied
        }
    }

    /// 启动采集。重复调用幂等。
    func start() throws {
        try sessionQueue.sync {
            guard !isRunning else { return }

            // ⚠️ 调用顺序铁律:beginConfiguration/commitConfiguration 之间只能改 io 配置,
            // 绝不能调 startRunning——否则抛 NSGenericException:
            //   "startRunning may not be called between calls to beginConfiguration and commitConfiguration"
            // 因此分两阶段:① 配置 io(失败时在 commit 前回滚);② commit 之后才 startRunning。
            session.beginConfiguration()

            // 防御性清理:上次启动若失败,input/output 可能已挂到 session 上却未回滚,
            // 若不清理,下次 start 时 canAddOutput(videoOutput) 会因 videoOutput 已归属本 session 而返回 false
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }

            session.sessionPreset = .hd1280x720 // PiP 显示宽度约为屏宽 1/4,720p 足够且省电

            // 配置阶段失败:必须在 commitConfiguration 前回滚本次已添加的 io,
            // 否则 commit 会落下一个无效配置,污染后续 start。
            // 用 do/catch 而非 defer:defer 会在 startRunning 之后才 commit,正好触发上面的铁律。
            do {
                guard let device = AVCaptureDevice.default(for: .video) else {
                    HostLog.write("camera: no device")
                    throw CameraError.noDevice
                }
                HostLog.write("camera: device=\(device.localizedName)")
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    HostLog.write("camera: cannot add input")
                    throw CameraError.startFailed("cannot add camera input")
                }
                session.addInput(input)

                // 统一输出 BGRA,与合成管线(CIContext 渲染目标)同格式,避免逐帧色彩转换
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoOutput.alwaysDiscardsLateVideoFrames = true // 只保留最新帧
                videoOutput.setSampleBufferDelegate(
                    self, queue: DispatchQueue(label: "com.screenrecord.camera.frames")
                )
                guard session.canAddOutput(videoOutput) else {
                    HostLog.write("camera: cannot add output")
                    throw CameraError.startFailed("cannot add camera output")
                }
                session.addOutput(videoOutput)
            } catch {
                // 配置失败:回滚本次已添加的 io,再提交(清空)配置,保持 session 干净
                for input in session.inputs { session.removeInput(input) }
                session.removeOutput(videoOutput)
                session.commitConfiguration()
                throw error
            }

            // 配置成功:提交后再启动(startRunning 必须在 commitConfiguration 之后)
            session.commitConfiguration()

            // 若 session 已处于 running(上次 stop 未真正停掉、或重入),startRunning() 是幂等的、
            // 但不会再次发 didStartRunningNotification → 等通知会误判超时(连录失败的根因)。
            // 故先查 isRunning:已在跑则直接成功,既不重复 startRunning 也不等通知。
            if session.isRunning {
                HostLog.write("camera: session already running (reuse, skip startRunning)")
                isRunning = true
                return
            }

            // startRunning 是耗时操作:同步调用返回后硬件仍在后台初始化,
            // 此时 session.isRunning 往往还是 false。用通知等 didStartRunning 判定真正就绪。
            // 桥接器接住可能抛的 ObjC 异常(防 SIGABRT),返回 nil=未抛异常,非 nil=异常描述。
            if let excDesc = SRCameraStartSession(session) {
                HostLog.write("camera: startRunning threw ObjC exception: \(excDesc)")
                rollbackIO(session)
                throw CameraError.startFailed("startRunning exception: \(excDesc)")
            }
            // 三个出口:didStartRunning=成功;runtimeError/didStopRunning=失败;10s 超时=失败。
            let startedOK = waitForSessionRunning(session, timeout: 10.0)
            guard startedOK else {
                HostLog.write("camera: session did not start (no didStartRunning within timeout)")
                rollbackIO(session)
                throw CameraError.startFailed("session failed to run (timed out waiting for didStartRunning)")
            }
            isRunning = true
            HostLog.write("camera: session running")
        }
    }

    /// 回滚本次 start 已添加的 input/output。
    /// startRunning 失败/超时时调用:commitConfiguration 已提交的 io 若不清理,
    /// 下次 start 时 canAddOutput 会因 videoOutput 仍归属本 session 返回 false(日志中的
    /// "cannot add output" 即此)。在 sessionQueue 内调用。
    private func rollbackIO(_ session: AVCaptureSession) {
        for input in session.inputs { session.removeInput(input) }
        // videoOutput 是实例属性,可能尚未 add;removeOutput 对未添加的 output 是安全的 no-op
        session.removeOutput(videoOutput)
    }

    /// 等待 session 真正进入 running 状态。
    /// startRunning() 同步返回后 isRunning 往往仍为 false(硬件在后台初始化),
    /// 唯一可靠的成功信号是 AVCaptureSession.didStartRunningNotification。
    /// 出口:didStartRunning → true;runtimeError / didStopRunning → false;超时 → false。
    /// 必须在 sessionQueue 上调用(与 startRunning 同队列,避免与配置提交交错)。
    private func waitForSessionRunning(_ session: AVCaptureSession, timeout: TimeInterval) -> Bool {
        let nc = NotificationCenter.default
        let sem = DispatchSemaphore(value: 0)
        // 原子标志:多个通知可能触发,只 signal 一次
        let done = NSLock()
        var signaled = false
        var didStart = false

        let signalOnce: (Bool) -> Void = { ok in
            done.lock()
            guard !signaled else { done.unlock(); return }
            signaled = true
            didStart = ok
            done.unlock()
            sem.signal()
        }

        let o1 = nc.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil) { _ in
            signalOnce(true)
        }
        let o2 = nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            HostLog.write("camera: runtimeError \(note.userInfo ?? [:])")
            signalOnce(false)
        }
        let o3 = nc.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil) { _ in
            signalOnce(false)
        }
        defer {
            nc.removeObserver(o1)
            nc.removeObserver(o2)
            nc.removeObserver(o3)
        }

        // startRunning 已在调用前执行;这里仅等待通知
        let waitResult = sem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            HostLog.write("camera: waitForSessionRunning TIMED OUT after \(timeout)s (isRunning=\(session.isRunning))")
            return false
        }
        done.lock()
        defer { done.unlock() }
        return didStart
    }

    /// 停止采集并释放帧缓存。幂等。
    func stop() {
        sessionQueue.sync {
            guard isRunning else { return }
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
            session.removeOutput(videoOutput)
            isRunning = false
            frameLock.lock()
            latestFrame = nil
            frameLock.unlock()
        }
    }

    /// 最新一帧(可能为 nil:刚启动尚无帧)。返回值已被 retain,调用方可跨线程安全使用。
    func currentFrame() -> CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        latestFrame = pixelBuffer
        frameLock.unlock()
    }
}
