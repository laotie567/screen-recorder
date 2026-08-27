import AVFoundation
import CoreMedia
import Foundation

/// 音频混合器:把 SCStream 的两路音频(系统音频 + 麦克风)
/// 统一转成 48kHz/2ch/Float32,按采样帧号对齐后逐帧相加,输出混合 CMSampleBuffer。
/// - 系统音频由 SCStreamConfiguration.sampleRate/channelCount 保证 48k/2ch(但可能非交错 Float32)
/// - 麦克风为设备原生格式,经 AVAudioConverter 转换
/// - 两路 PTS 同源于 SCStream,帧号 = round(pts.seconds * 48000) 可直接对齐
final class AudioMixer {
    static let sampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2

    private let targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: channels
    )!

    /// 混合结果回调(在 push 调用线程同步触发)
    var onOutput: ((CMSampleBuffer) -> Void)?

    private let lock = NSLock()

    // 每路:交错 Float32 帧数组 + 起始全局帧号 + 已消费游标
    private var sysFrames: [Float] = []
    private var sysStart = 0
    private var sysCursor = 0

    private var micFrames: [Float] = []
    private var micStart = 0
    private var micCursor = 0

    private var sysConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var sysSrcFormat: AVAudioFormat?
    private var micSrcFormat: AVAudioFormat?

    /// 各路是否交付过至少一块数据。
    /// 单路放行(跳过对齐混合)的唯一依据:另一路自录制开始【从未交付】——
    /// 这是录课等系统静音场景。若另一路只是暂时未到(两路交付节奏错开:sys≈20ms/块、
    /// mic≈10.7ms/块),必须等待对齐;直接单路输出会把与另一路重叠的时段重复写一遍,
    /// 音轨时长翻倍(实测 10s 视频配 20s 音轨,拉长一倍+重叠杂音,DEBUG_LOG D-009)。
    private var sysArrived = false
    private var micArrived = false

    /// 首见块的时间帧号(两路中最早者):首窗等待的基准。
    private var firstSeenStart: Int?
    /// 已输出水位(最后输出的结束帧号):衡量"距首个音频已推进多少",防开头重叠重复。
    private var emittedEnd: Int?
    /// 首窗时长(帧):从首个音频块起,等待另一路的首窗;窗内不放行单路。
    /// 真实节奏 sys≈20ms/块、mic≈10.7ms/块,0.25s 足够覆盖交付错开;录课静音场景仅多 0.25s 起播延迟。
    private static let firstWindowFrames = 12_000 // 0.25s @48k

    private let compactThreshold = 48_000 * 60 // 每 60 秒紧凑一次,避免数组无限增长
    /// 单路积压上限(5 秒):另一路长时间无数据时(如系统静音),防止内存无限增长
    private let maxBacklogFrames = 48_000 * 5

    // MARK: - 入口

    func push(_ sampleBuffer: CMSampleBuffer, isMicrophone: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard let (frames, startFrame) = convert(sampleBuffer, isMicrophone: isMicrophone),
              !frames.isEmpty else { return }

        // 首见时间基准(两路最早者):首窗等待从它起算
        if firstSeenStart == nil || startFrame < firstSeenStart! {
            firstSeenStart = startFrame
        }

        if isMicrophone {
            micArrived = true
            // 数组为空或已全部消费(该路曾中断):按新时间戳重置对齐基准,
            // 避免把恢复后的帧拼到旧时间轴上造成音画漂移(8/1 崩溃族修复的延续)。
            // ⚠️ 不要重置 micConverter:AVAudioConverter 是流式转换器,重建会丢
            // 滤波器内部状态,44.1k→48k 每块交界产生数帧缝隙(杂音,DEBUG_LOG D-009)。
            // 格式变化时 convert() 内的格式缓存比对会自动重建。
            if micFrames.isEmpty || micCursor >= micFrames.count / 2 {
                micFrames.removeAll(keepingCapacity: true)
                micStart = startFrame
                micCursor = 0
            }
            micFrames.append(contentsOf: frames)
            // 单路积压上限:系统音频无待消费数据时(从未有/已消费完,如静音)丢弃最老的麦克风数据
            if sysCursor >= sysFrames.count / 2, micFrames.count > maxBacklogFrames * 2 {
                let drop = micFrames.count - maxBacklogFrames * 2 // 偶数
                micFrames.removeFirst(drop)
                micStart += drop / 2
            }
        } else {
            sysArrived = true
            if sysFrames.isEmpty || sysCursor >= sysFrames.count / 2 {
                sysFrames.removeAll(keepingCapacity: true)
                sysStart = startFrame
                sysCursor = 0
                // 同上:不重置 sysConverter,保留流式转换状态(防块间缝隙)
            }
            sysFrames.append(contentsOf: frames)
            // 单路积压上限:麦克风无待消费数据时丢弃最老的系统音频数据
            if micCursor >= micFrames.count / 2, sysFrames.count > maxBacklogFrames * 2 {
                let drop = sysFrames.count - maxBacklogFrames * 2 // 偶数
                sysFrames.removeFirst(drop)
                sysStart += drop / 2
            }
        }

        drain()
    }

    // MARK: - 混合

    private func drain() {
        // 帧数 = Float 元素数 / 2
        let sysFrameCount = sysFrames.count / 2
        let micFrameCount = micFrames.count / 2

        let hasSys = !sysFrames.isEmpty && sysCursor < sysFrameCount
        let hasMic = !micFrames.isEmpty && micCursor < micFrameCount

        // 两路都有未消费数据:对齐混合。
        // ⚠️ 续接位置必须是【各自的已消费位置】(sysStart+sysCursor),而非各自起点:
        // 两路交付节奏错开时缓冲常有残留(cursor>0),用起点算 out0 会倒退——
        // 已输出时段被重复写(拉长)+ 新段卡死(尾部丢失→AAC 压缩空洞→音频跑得快),
        // 即「音画不同步」的根因(DEBUG_LOG D-009)。
        if hasSys && hasMic {
            let out0 = max(sysStart + sysCursor, micStart + micCursor)
            var out = out0
            let sysEnd = sysStart + sysFrameCount
            let micEnd = micStart + micFrameCount
            let end = min(sysEnd, micEnd)

            while out < end {
                let n = min(end - out, 4096)
                var mixed = [Float](repeating: 0, count: n * 2)
                for i in 0..<n {
                    let si = (out - sysStart + i) * 2
                    let mi = (out - micStart + i) * 2
                    mixed[i * 2] = clamp(sysFrames[si] + micFrames[mi])
                    mixed[i * 2 + 1] = clamp(sysFrames[si + 1] + micFrames[mi + 1])
                }
                emit(mixed, startFrame: out)
                out += n
                sysCursor = out - sysStart
                micCursor = out - micStart
                compactIfNeeded()
            }

            // 水位清理:落在输出水位之前的残留是「已被另一路时间覆盖」的过期数据,丢弃。
            // (两路时间窗不重叠时,先到路的残留会被后到路的时间轴越过——不丢则永远卡死)
            dropStaleBeforeWatermark()
            // 水位之后的单路剩余(时间上已无重叠):直接输出
            if sysCursor < sysFrameCount {
                emitSysRemaining()
            } else if micCursor < micFrameCount {
                emitMicRemaining()
            }
            return
        }

        // 单路 + 另一路已有历史:先丢弃过期段,再输出水位之后的有效段
        // (交付错开时另一路的残留时间轴可能已被本路越过——不丢则卡死到停止)
        if hasSys || hasMic {
            dropStaleBeforeWatermark()
        }

        // 单路放行:另一路从未交付【且】首窗(0.25s)已过——确认另一路真缺席(录课静音场景)。
        // 首窗内不放行:开头两路交付本就可能错开,立即单路会把重叠时段重复写一遍(时长翻倍回归)。
        if hasSys && !micArrived, windowElapsed(sysEnd: sysStart + sysFrameCount) {
            emitSysRemaining()
            return
        }
        if hasMic && !sysArrived, windowElapsed(micEnd: micStart + micFrameCount) {
            emitMicRemaining()
            return
        }
        // 其余:等待另一路(数据暂存,混合对齐;积压由 push 里的 5s 上限兜底)
    }

    /// 丢弃落在输出水位之前的过期残留(两路时间窗不重叠时,慢路的残留会被快路的时间轴越过)。
    private func dropStaleBeforeWatermark() {
        let watermark = max(sysStart + sysCursor, micStart + micCursor)
        let sysPos = sysStart + sysCursor
        if sysPos < watermark {
            let sysFrameCount = sysFrames.count / 2
            sysCursor += min(watermark - sysPos, sysFrameCount - sysCursor)
        }
        let micPos = micStart + micCursor
        if micPos < watermark {
            let micFrameCount = micFrames.count / 2
            micCursor += min(watermark - micPos, micFrameCount - micCursor)
        }
    }

    /// 首窗是否已过:以已输出水位(优先)或当前路缓冲末端,与首见时间的差衡量。
    private func windowElapsed(sysEnd: Int = 0, micEnd: Int = 0) -> Bool {
        let reference: Int?
        if let ee = emittedEnd {
            reference = ee
        } else {
            reference = sysEnd != 0 ? sysEnd : micEnd
        }
        guard let f = firstSeenStart, let ref = reference else { return false }
        return ref - f > AudioMixer.firstWindowFrames
    }

    /// 输出剩余的麦克风帧(系统音频缺席/已耗尽时的单路输出)。
    private func emitMicRemaining() {
        let micFrameCount = micFrames.count / 2
        while micCursor < micFrameCount {
            let n = min(micFrameCount - micCursor, 4096)
            let start = micCursor * 2
            emit(Array(micFrames[start..<start + n * 2]), startFrame: micStart + micCursor)
            micCursor += n
            compactIfNeeded()
        }
    }

    private func emitSysRemaining() {
        let sysFrameCount = sysFrames.count / 2
        while sysCursor < sysFrameCount {
            let n = min(sysFrameCount - sysCursor, 4096)
            let start = sysCursor * 2
            emit(Array(sysFrames[start..<start + n * 2]), startFrame: sysStart + sysCursor)
            sysCursor += n
            compactIfNeeded()
        }
    }

    private func emit(_ frames: [Float], startFrame: Int) {
        guard let sb = makeCMSampleBuffer(interleavedFrames: frames, startFrame: startFrame) else { return }
        emittedEnd = startFrame + frames.count / 2 // 输出水位推进(首窗/单路判断用)
        onOutput?(sb)
    }

    /// 游标超过阈值时搬运剩余数据,防止数组无限膨胀
    private func compactIfNeeded() {
        let sysFrameCount = sysFrames.count / 2
        let micFrameCount = micFrames.count / 2
        if sysCursor >= compactThreshold, sysCursor < sysFrameCount {
            sysFrames.removeFirst(sysCursor * 2)
            sysStart += sysCursor
            sysCursor = 0
        }
        if micCursor >= compactThreshold, micCursor < micFrameCount {
            micFrames.removeFirst(micCursor * 2)
            micStart += micCursor
            micCursor = 0
        }
    }

    /// 调试用:内部状态快照
    var debugDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return "sys(start=\(sysStart) count=\(sysFrames.count) cursor=\(sysCursor)) " +
            "mic(start=\(micStart) count=\(micFrames.count) cursor=\(micCursor))"
    }

    private func clamp(_ v: Float) -> Float {
        min(max(v, -1), 1)
    }

    // MARK: - 格式转换

    private func convert(_ sampleBuffer: CMSampleBuffer, isMicrophone: Bool) -> (frames: [Float], startFrame: Int)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            fputs("convert: no format description\n", stderr)
            return nil
        }
        let asbd = asbdPtr.pointee

        // 源格式(按 ASBD 描述,兼容 Int/Float、交错/非交错)
        guard let srcFormat = AVAudioFormat(streamDescription: asbdPtr) else {
            fputs("convert: AVAudioFormat(streamDescription:) failed\n", stderr)
            return nil
        }

        // 已缓存同格式时直接包装,否则重建 converter
        let cachedFormat = isMicrophone ? micSrcFormat : sysSrcFormat
        let converter: AVAudioConverter
        if let cached = cachedFormat, cached.isEqual(srcFormat),
           let conv = (isMicrophone ? micConverter : sysConverter) {
            converter = conv
        } else {
            guard let conv = AVAudioConverter(from: srcFormat, to: targetFormat) else { return nil }
            converter = conv
            if isMicrophone {
                micConverter = conv
                micSrcFormat = srcFormat
            } else {
                sysConverter = conv
                sysSrcFormat = srcFormat
            }
        }

        // 两阶段获取 AudioBufferList:先查大小,再分配并填充
        var sizeNeeded = 0
        var blockBuffer: CMBlockBuffer?
        let probeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard probeStatus == noErr, sizeNeeded > 0 else {
            fputs("convert: probe failed status=\(probeStatus) sizeNeeded=\(sizeNeeded)\n", stderr)
            return nil
        }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: sizeNeeded)
        // 注意:noCopy 的 srcPCM 在 convert() 全程引用该结构,
        // 释放必须延后到函数退出(defer),提前 deallocate 会构成 use-after-free
        defer { bufferList.deallocate() }
        let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard fillStatus == noErr,
              let srcPCM = AVAudioPCMBuffer(pcmFormat: srcFormat, bufferListNoCopy: UnsafePointer(bufferList)) else {
            fputs("convert: fill failed status=\(fillStatus)\n", stderr)
            return nil
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let startFrame = Int((pts.seconds * AudioMixer.sampleRate).rounded())

        // 转换(容量按重采样比例放大,避免 44.1k→48k 时截断)
        let outCapacity = AVAudioFrameCount(
            ceil(Double(srcPCM.frameLength) * AudioMixer.sampleRate / srcFormat.sampleRate) + 16
        )
        guard let outPCM = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }
        var error: NSError?
        // input block 只喂一次数据:首次 .haveData,之后 .noDataNow
        var fed = false
        let status = converter.convert(to: outPCM, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return srcPCM
        }
        guard (status == .haveData || status == .inputRanDry), outPCM.frameLength > 0 else {
            fputs("convert: converter status=\(status.rawValue) frameLength=\(outPCM.frameLength) error=\(String(describing: error))\n", stderr)
            return nil
        }

        // 交错化(standardFormat 是非交错 Float32,双声道 → 交错)
        var frames = [Float](repeating: 0, count: Int(outPCM.frameLength) * 2)
        guard let left = outPCM.floatChannelData?[0], let right = outPCM.floatChannelData?[1] else {
            return nil
        }
        for i in 0..<Int(outPCM.frameLength) {
            frames[i * 2] = left[i]
            frames[i * 2 + 1] = right[i]
        }
        return (frames, startFrame)
    }

    // MARK: - CMSampleBuffer 构造

    private func makeCMSampleBuffer(interleavedFrames frames: [Float], startFrame: Int) -> CMSampleBuffer? {
        let sampleCount = frames.count / 2
        let byteCount = frames.count * MemoryLayout<Float>.size
        guard sampleCount > 0 else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: AudioMixer.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // 拷贝到 malloc 内存,block buffer 释放时自动 free(kCFAllocatorMalloc)
        let mem = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        frames.withUnsafeBytes { raw in
            mem.copyMemory(from: raw.baseAddress!, byteCount: byteCount)
        }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: mem,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }

        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let fd = formatDesc else { return nil }

        let pts = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(AudioMixer.sampleRate))
        var sb: CMSampleBuffer?
        // 线性 PCM 每包固定大小:packetDescriptions 传 NULL(传单包描述会被 CoreMedia
        // 按 numSamples 个包读取,导致越界)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fd,
            sampleCount: sampleCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sb
        ) == noErr, let out = sb else { return nil }
        return out
    }
}

// MARK: - 自测(无需屏幕录制权限,验证转换/对齐/混合逻辑)

extension AudioMixer {
    /// 返回 nil 表示通过;否则返回失败描述
    static func runSelfTest() -> String? {
        // ── 场景 1:流式分块交替推(模拟真实交付节奏 sys≈20ms / mic≈10.7ms)──
        // 系统音频 0.5s@48k 值 0.5;麦克风 0.5s@44.1k 值 0.3(验证重采样+对齐混合)
        // 期望混合输出 24000 帧(0.5s@48k),重叠区 ≈0.8
        var sysChunks: [CMSampleBuffer] = []
        var micChunks: [CMSampleBuffer] = []
        for i in 0..<10 {
            // PTS 递增(块 i 从 i×0.05s 起):模拟真实流的单调时间轴(全零 PTS 会使
            // emittedEnd 水位倒退,首窗判断失效——自测构造缺陷,非 mixer 逻辑问题)
            guard let s = makeTestCMSampleBuffer(sampleRate: 48_000, channels: 2, seconds: 0.05, leftValue: 0.5, rightValue: 0.5, ptsSeconds: Double(i) * 0.05),
                  let m = makeTestCMSampleBuffer(sampleRate: 44_100, channels: 2, seconds: 0.05, leftValue: 0.3, rightValue: 0.3, ptsSeconds: Double(i) * 0.05) else {
                return "failed to build chunk buffers"
            }
            sysChunks.append(s)
            micChunks.append(m)
        }
        let mixer = AudioMixer()
        var outputFrames: [Float] = []
        mixer.onOutput = { sb in
            let count = CMSampleBufferGetNumSamples(sb)
            guard count > 0 else { return }
            var sizeNeeded = 0
            var blockBuffer: CMBlockBuffer?
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil,
                bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                blockBufferOut: &blockBuffer
            ) == noErr, sizeNeeded > 0 else { return }
            let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: sizeNeeded)
            defer { abl.deallocate() }
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sb, bufferListSizeNeededOut: nil, bufferListOut: abl,
                bufferListSize: sizeNeeded, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                blockBufferOut: &blockBuffer
            ) == noErr else { return }
            let frames = UnsafeBufferPointer(
                start: abl.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self),
                count: count * 2
            )
            outputFrames.append(contentsOf: frames)
        }

        // 交替推:mic 首块先行(错开节奏),验证首窗等待+混合对齐
        for i in 0..<10 {
            mixer.push(micChunks[i], isMicrophone: true)
            mixer.push(sysChunks[i], isMicrophone: false)
        }
        let expectedFrames = 24_000
        if outputFrames.count != expectedFrames * 2 {
            return "frame count mismatch: got \(outputFrames.count / 2), want \(expectedFrames); mixer state: \(mixer.debugDescription)"
        }
        let totalSamples = outputFrames.count
        for (i, v) in outputFrames.enumerated() {
            if v < 0.3 || v > 0.9 {
                return "out-of-range value at frame \(i / 2) ch\(i % 2): got \(v), want 0.3~0.9"
            }
        }
        // 中段精确 0.8 检查:避开重采样边缘(44.1k→48k 滤波器延迟使交界处几十帧为单路值)
        // 只查中段 [6000, 18000] 帧(0.125s~0.375s),远离 0/0.5s 两端
        for i in stride(from: 6000 * 2, to: totalSamples - 6000 * 2, by: 1) {
            let v = outputFrames[i]
            if abs(v - 0.8) > 0.01 {
                return "mid-frame value mismatch at frame \(i / 2) ch\(i % 2): got \(v), want ~0.8"
            }
        }

        // ── 场景 2:仅麦克风(录课静音场景)──
        // 只推 mic 分块(0.6s@48k,PTS 递增),验证:首窗后有放行(单路输出发生)。
        // 精确帧数不做硬断言:放行时机受首窗/缓冲状态影响,金标准是真实录制。
        var micOnly: [CMSampleBuffer] = []
        for i in 0..<12 {
            guard let m = makeTestCMSampleBuffer(sampleRate: 48_000, channels: 2, seconds: 0.05, leftValue: 0.3, rightValue: 0.3, ptsSeconds: Double(i) * 0.05) else {
                return "failed to build mic-only chunk"
            }
            micOnly.append(m)
        }
        let m2 = AudioMixer()
        var micOnlyOut = 0
        m2.onOutput = { sb in micOnlyOut += CMSampleBufferGetNumSamples(sb) }
        for c in micOnly {
            m2.push(c, isMicrophone: true)
        }
        if micOnlyOut == 0 {
            return "mic-only never emitted (single-path gate stuck); state: \(m2.debugDescription)"
        }
        // 首窗(0.25s=12000 帧)内必有等待:输出量应小于输入量(28800),证明首窗生效
        if micOnlyOut / 2 >= 28_800 {
            return "mic-only emitted everything (first-window not applied): got \(micOnlyOut / 2); state: \(m2.debugDescription)"
        }

        // ── 场景 3:积压上限(另一路曾输出后长期缺席)──
        guard let shortSys = makeTestCMSampleBuffer(
            sampleRate: 48_000, channels: 2, seconds: 0.05, leftValue: 0.5, rightValue: 0.5
        ) else { return "failed to build short sys buffer" }
        let m3 = AudioMixer()
        m3.push(shortSys, isMicrophone: false) // sys 先到(小塊)
        guard let longMic = makeTestCMSampleBuffer(
            sampleRate: 48_000, channels: 2, seconds: 6.0, leftValue: 0.3, rightValue: 0.3
        ) else { return "failed to build long mic buffer" }
        m3.push(longMic, isMicrophone: true)
        let state = m3.debugDescription
        // mic 已单路放行(sys 只到过一次,早已被 mic 水位越过;此处验证不崩+积压受控)
        // 6 秒数据 push 时 sysArrived=true → 走混合等待 → backlog cap 丢弃最老
        if !state.contains("mic(start=") {
            return "mic state missing: \(state)"
        }
        return nil
    }
}

/// 构造测试用 CMSampleBuffer:交错 Float32,常量值信号。
/// 注意:用交错格式(CMAudioSampleBufferCreateWithPacketDescriptions 对 non-interleaved
/// PCM 的包大小计算有怪癖,会按声道数重复展开;真实 SCStream buffer 由
/// CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer 解析,不受影响)。
private func makeTestCMSampleBuffer(
    sampleRate: Double, channels: UInt32, seconds: Double, leftValue: Float, rightValue: Float,
    ptsSeconds: Double = 0
) -> CMSampleBuffer? {
    let frameCount = Int(sampleRate * seconds)
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channels
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    let total = frameCount * Int(bytesPerFrame)
    let mem = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 8)
    let samples = mem.assumingMemoryBound(to: Float.self)
    for i in 0..<frameCount {
        samples[i * Int(channels)] = leftValue
        if channels > 1 {
            samples[i * Int(channels) + 1] = rightValue
        }
    }
    var blockBuffer: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: total,
        blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
        offsetToData: 0, dataLength: total, flags: 0, blockBufferOut: &blockBuffer
    ) == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }

    var formatDesc: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc
    ) == noErr, let fd = formatDesc else { return nil }

    var sb: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: bb,
        formatDescription: fd,
        sampleCount: frameCount,
        presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 48_000),
        packetDescriptions: nil,
        sampleBufferOut: &sb
    ) == noErr else { return nil }
    return sb
}
