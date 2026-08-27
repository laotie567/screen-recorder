import AppKit
import AVFoundation
import CoreVideo
import Foundation

/// 录制中的摄像头悬浮窗(所见即所得)。
///
/// 设计要点:
/// - 用 `AVCaptureVideoPreviewLayer` 实时显示摄像头。因为 ScreenCaptureKit 的
///   `SCContentFilter(excludingWindows: [])` 不排除任何窗口,本浮窗会被自然捕获进录屏——
///   用户拖动/缩放浮窗 = 调整 MP4 里摄像头的位置/大小,零延迟、零合成开销。
/// - 圆形:正方形 window + `cornerRadius = width/2` + `masksToBounds = true`。
/// - 白边 2px + 系统柔和阴影。
/// - 交互(在 OverlayContentView 中显式处理):
///   · 按住主体拖动 → 移动窗口(用 drag-by-background 的显式实现,而非 isMovableByWindowBackground)
///   · 右下角命中区拖动 → 等比缩放(按鼠标到中心距离)
///   · 滚轮 → 缩放(保持中心)
///
/// 所有 NSPanel 操作在主线程;show/hide 内部已派发到主队列。
/// 单例:录制开始 show、结束 hide,跨次录制复用同一实例与上次位置/大小。
final class CameraOverlayPanel: NSPanel {
    static let shared = CameraOverlayPanel()

    /// 尺寸上下限(逻辑点)。fileprivate:同文件 OverlayContentView 的 resize 命中需访问。
    fileprivate static let minSize: CGFloat = 80
    fileprivate static let maxSizeRatio: CGFloat = 0.4 // 屏宽的 40%
    /// 默认尺寸:屏宽 12%(录课时人脸占比更合适;仍可用滚轮/手柄随时调整)。
    private static let defaultSizeRatio: CGFloat = 0.12
    private static let defaultMarginRatio: CGFloat = 0.04
    /// 右下角 resize 命中区边长(逻辑点)。fileprivate:同文件的 OverlayContentView 也需访问。
    fileprivate static let handleHitSize: CGFloat = 28

    /// 上次位置:跨次录制复用。nil=用默认右下角。
    private(set) var lastFrame: CGRect?

    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var resizeHandle: NSView?

    private override init(contentRect: NSRect, styleMask aStyle: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        // borderless + nonactivatingPanel:不抢焦点、不进 Dock,纯悬浮
        let mask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        super.init(contentRect: contentRect, styleMask: mask, backing: .buffered, defer: false)

        // level 用 statusBar(高于普通 floating),确保切换到其他 app(如微信)时浮窗不被遮挡。
        // .floating 在某些 app 抢占前台时会被压下去,导致"切窗摄像头消失"。
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        // 用 AppKit 内置的背景拖动处理"移动"(最可靠,自动处理边界/光标/惯性)。
        // resize 在 OverlayContentView.mouseDown 里显式判断:命中右下角则走 resize,
        // 否则返回 mouseDownCanMoveWindow=true 让 AppKit 接管移动。
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        // 关键:app 失活(切到其他 app)时不隐藏浮窗。nonactivatingPanel 在前台 app 切换时
        // 默认会 hide,导致"切到微信摄像头消失"。显式 false + 下面的通知保活双保险。
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = false
        self.titleVisibility = .hidden
        self.title = ""

        let cv = OverlayContentView()
        cv.panel = self
        cv.wantsLayer = true
        self.contentView = cv
    }

    // MARK: - 公开 API

    /// 显示浮窗并挂上摄像头预览。
    /// - Parameter session:`CameraCapture.shared.previewSession`(已 startRunning)。
    func show(previewSession: AVCaptureSession?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let previewSession {
                self.previewLayer.session = previewSession
                self.previewLayer.videoGravity = .resizeAspectFill
            }
            self.prepareForDisplay()
            self.orderFrontRegardless()
            self.startKeepAlive()
        }
    }

    // MARK: - 保活:切换前台 app 时强制保持浮窗可见

    /// 监听其他 app 抢占前台(didResignActive / didBecomeActive 通知),
    /// 延迟一小段时间后重新 orderFrontRegardless,确保浮窗不被其他窗口遮挡。
    /// 之前切到微信等 app 浮窗"消失"即此处未保活;statusBar level + 此监听双保险。
    private var keepAliveObservers: [NSObjectProtocol] = []
    private var keepAliveWorkItem: DispatchWorkItem?

    private func startKeepAlive() {
        // 幂等:已注册则跳过
        guard keepAliveObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        // app 失活(切到别的 app):短暂延迟后重新置顶(避免与系统动画冲突)
        let o1 = nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rescheduleKeepAlive()
        }
        // 窗口聚焦变化:其他 app 的窗口聚焦时也尝试保活
        let o2 = nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rescheduleKeepAlive()
        }
        keepAliveObservers = [o1, o2]
    }

    private func stopKeepAlive() {
        let nc = NotificationCenter.default
        keepAliveObservers.forEach { nc.removeObserver($0) }
        keepAliveObservers = []
        keepAliveWorkItem?.cancel()
        keepAliveWorkItem = nil
    }

    /// 延迟 0.3s 重新置顶(合并连续通知,避免抖动)。
    private func rescheduleKeepAlive() {
        guard isVisible else { return }
        keepAliveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.orderFrontRegardless()
        }
        keepAliveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// 隐藏浮窗(不销毁,下次 show 复用)。记录当前 frame 供下次复用。
    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isVisible {
                self.lastFrame = self.frame
            }
            self.stopKeepAlive()
            self.orderOut(nil)
        }
    }

    // MARK: - 布局 / 圆形外观

    private func prepareForDisplay() {
        let target = lastFrame ?? CameraOverlayPanel.defaultFrame()
        let clamped = CameraOverlayPanel.clampSize(target.width)
        let f = NSRect(x: target.origin.x, y: target.origin.y, width: clamped, height: clamped)
        setFrame(f, display: true)
        layoutSubviews(size: f.size)
    }

    /// 按 size 布局圆角/边框/预览层/手柄。幂等。
    private func layoutSubviews(size: CGSize) {
        guard let view = contentView, let layer = view.layer else { return }
        view.frame = NSRect(origin: .zero, size: size)
        // 正圆:正方形 window + cornerRadius = 边长/2
        layer.cornerRadius = min(size.width, size.height) / 2
        layer.borderWidth = 2
        layer.borderColor = NSColor.white.cgColor
        layer.masksToBounds = true

        // 预览层首次挂载;之后只更新 frame
        if previewLayer.superlayer == nil {
            layer.addSublayer(previewLayer)
        }
        previewLayer.frame = layer.bounds

        // resize 手柄首次创建;之后只更新位置
        if resizeHandle == nil {
            let handle = ResizeHandleView()
            handle.wantsLayer = true
            let hl = handle.layer!
            hl.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            hl.cornerRadius = 7
            hl.borderWidth = 1
            hl.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
            view.addSubview(handle)
            resizeHandle = handle
        }
        let hs: CGFloat = 14
        resizeHandle?.frame = NSRect(x: size.width - hs - 6, y: 6, width: hs, height: hs)
    }

    // MARK: - 默认 frame / 尺寸 clamp

    private static func defaultFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 200, height: 200)
        }
        let r = screen.visibleFrame
        let size = (r.width * defaultSizeRatio).rounded()
        let margin = (r.width * defaultMarginRatio).rounded()
        return NSRect(x: r.maxX - size - margin, y: r.minY + margin, width: size, height: size)
    }

    fileprivate static func clampSize(_ size: CGFloat) -> CGFloat {
        let maxByScreen = (NSScreen.main?.visibleFrame.width ?? 1000) * maxSizeRatio
        return min(max(size, minSize), maxByScreen)
    }

    // MARK: - resize(由 OverlayContentView 拖拽时调用)

    /// 设置为指定直径,保持窗口中心不变。
    fileprivate func resizeTo(diameter: CGFloat) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let newFrame = NSRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        setFrame(newFrame, display: true, animate: false)
        layoutSubviews(size: newFrame.size)
    }

    /// 限制窗口 origin 在屏幕可视区内(防止拖到屏幕外不可见)。
    private func constrainOrigin(_ origin: CGPoint) -> CGPoint {
        guard let screen = NSScreen.main else { return origin }
        let r = screen.visibleFrame
        let w = frame.width, h = frame.height
        let x = min(max(origin.x, r.minX), r.maxX - w)
        let y = min(max(origin.y, r.minY), r.maxY - h)
        return CGPoint(x: x, y: y)
    }

    // MARK: - 滚轮缩放(保持中心)

    override func scrollWheel(with event: NSEvent) {
        let delta = event.deltaY
        guard abs(delta) >= 0.01 else { return }
        let scale: CGFloat = delta > 0 ? 1.06 : 1 / 1.06
        let newSize = CameraOverlayPanel.clampSize(frame.width * scale)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let newFrame = NSRect(
            x: center.x - newSize / 2, y: center.y - newSize / 2,
            width: newSize, height: newSize
        )
        setFrame(newFrame, display: true, animate: false)
        layoutSubviews(size: newFrame.size)
    }
}

// MARK: - 内容视图(移动交给 AppKit,resize 显式处理)

/// 圆形浮窗的内容视图。
/// - 移动:交给 AppKit 的 isMovableByWindowBackground(最可靠),通过 mouseDownCanMoveWindow
///   在 resize 命中区返回 false 来「让出」该区域的移动权。
/// - resize:命中右下角时,本视图的 mouseDown/mouseDragged 接管,按鼠标到中心距离等比缩放。
///   mouseDownCanMoveWindow=false 时 AppKit 不拦截 mouseDown,事件到达本视图。
private final class OverlayContentView: NSView {
    fileprivate weak var panel: CameraOverlayPanel?

    /// resize 拖拽基准:按下时鼠标到中心的距离 / 当时的半径。
    /// 用比值而非绝对距离,避免初始直径与拖动距离不匹配导致跳变。
    private var resizeBaseRatio: CGFloat = 0
    private var isResizing = false

    /// 关键:决定本次 mouseDown 是否让 AppKit 走「背景拖动移动窗口」。
    /// 落在右下角 resize 命中区 → false(AppKit 不拦截,事件进入本视图的 mouseDown 走 resize)。
    /// 其余区域 → true(AppKit 接管移动)。
    override var mouseDownCanMoveWindow: Bool {
        guard let window else { return true }
        // 用屏幕坐标判断命中,绕过 borderless/圆角窗的本地坐标系坑
        let screenPt = NSEvent.mouseLocation
        let f = window.frame
        let hitSize = CameraOverlayPanel.handleHitSize
        // 右下角命中区:屏幕坐标系下 y 越小越靠下(macOS 屏幕坐标原点在左下)
        let inRightEdge = screenPt.x >= f.maxX - hitSize
        let inBottomEdge = screenPt.y <= f.minY + hitSize
        return !(inRightEdge && inBottomEdge)
    }

    override func mouseDown(with event: NSEvent) {
        // 仅当落在 resize 命中区(mouseDownCanMoveWindow=false)时,AppKit 才把事件送来
        guard let window, let panel, !mouseDownCanMoveWindow else { return }
        isResizing = true
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let mp = NSEvent.mouseLocation
        let dx = mp.x - center.x, dy = mp.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        // 基准 = 当前距离 / 当前半径;拖动时新半径 = 新距离 / 基准
        let curRadius = window.frame.width / 2
        resizeBaseRatio = dist > 1 ? dist / curRadius : 1
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing, let window, let panel else { return }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let mp = NSEvent.mouseLocation
        let dx = mp.x - center.x, dy = mp.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        let newRadius = resizeBaseRatio > 0 ? dist / resizeBaseRatio : dist
        let newDiameter = CameraOverlayPanel.clampSize(newRadius * 2)
        panel.resizeTo(diameter: newDiameter)
    }

    override func mouseUp(with event: NSEvent) {
        isResizing = false
    }

    override func resetCursorRects() {
        // resize 命中区:十字光标;其余:默认(AppKit 背景拖动会显示移动光标)
        guard let cv = panel?.contentView ?? self.superview else { return }
        let r = cv.bounds
        let hitZone = NSRect(x: r.maxX - CameraOverlayPanel.handleHitSize,
                             y: r.minY, width: CameraOverlayPanel.handleHitSize,
                             height: CameraOverlayPanel.handleHitSize)
        addCursorRect(hitZone, cursor: .crosshair)
    }
}

// MARK: - resize 手柄(纯视觉装饰)

/// 右下角小圆点。仅视觉提示,不接收鼠标事件(hitTest 返回 nil),让事件穿透到
/// OverlayContentView,由 panel.hitTestForResize 统一处理更大的命中区。
private final class ResizeHandleView: NSView {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 不参与命中测试:否则鼠标点在手柄上会被它吃掉,OverlayContentView 收不到 mouseDown。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
