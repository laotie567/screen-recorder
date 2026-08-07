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

    private let compactThreshold = 48_000 * 60 // 每 60 秒紧凑一次,避免数组无限增长
    /// 单路积压上限(5 秒):另一路长时间无数据时(如系统静音),防止内存无限增长
    private let maxBacklogFrames = 48_000 * 5

    // MARK: - 入口

    func push(_ sampleBuffer: CMSampleBuffer, isMicrophone: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard let (frames, startFrame) = convert(sampleBuffer, isMicrophone: isMicrophone),
              !frames.isEmpty else { return }

        if isMicrophone {
            // 数组为空或已全部消费(该路曾中断):按新时间戳重置对齐基准,
            // 避免把恢复后的帧拼到旧时间轴上造成音画漂移(8/1 崩溃族修复的延续)
            if micFrames.isEmpty || micCursor >= micFrames.count / 2 {
                micFrames.removeAll(keepingCapacity: true)
                micStart = startFrame
                micCursor = 0
                micConverter = nil // 重置,格式缓存按需重建
            }
            micFrames.append(contentsOf: frames)
            // 单路积压上限:系统音频无待消费数据时(从未有/已消费完,如静音)丢弃最老的麦克风数据
            if sysCursor >= sysFrames.count / 2, micFrames.count > maxBacklogFrames * 2 {
                let drop = micFrames.count - maxBacklogFrames * 2 // 偶数
                micFrames.removeFirst(drop)
                micStart += drop / 2
            }
        } else {
            if sysFrames.isEmpty || sysCursor >= sysFrames.count / 2 {
                sysFrames.removeAll(keepingCapacity: true)
                sysStart = startFrame
                sysCursor = 0
                sysConverter = nil
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

        // 无系统音频:无从混合(系统音频是主轨)
        guard !sysFrames.isEmpty, sysCursor < sysFrameCount else { return }

        // 无麦克风数据:系统音频原样输出
        guard !micFrames.isEmpty, micCursor < micFrameCount else {
            emitSysRemaining()
            return
        }

        // 两路都有:从两路起始帧号较大者开始对齐输出,直到任一路耗尽
        let out0 = max(sysStart, micStart)
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

        // 一路先耗尽:剩余部分只输出系统音频
        if sysCursor < sysFrameCount && micCursor >= micFrameCount {
            emitSysRemaining()
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
        // 系统音频:48000Hz/2ch,0.5s,常量 0.5(非交错 Float32)
        guard let sysBuffer = makeTestCMSampleBuffer(
            sampleRate: 48_000, channels: 2, seconds: 0.5, leftValue: 0.5, rightValue: 0.5
        ) else { return "failed to build system audio buffer" }
        // 麦克风:44100Hz/2ch,0.5s,常量 0.3 —— 不同采样率,验证重采样+对齐
        guard let micBuffer = makeTestCMSampleBuffer(
            sampleRate: 44_100, channels: 2, seconds: 0.5, leftValue: 0.3, rightValue: 0.3
        ) else { return "failed to build mic buffer" }

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

        // 先推 mic 再推系统音频:验证起始对齐
        mixer.push(micBuffer, isMicrophone: true)
        mixer.push(sysBuffer, isMicrophone: false)

        // 期望:0.5s@48k = 24000 帧
        // 结构:混合区(mic 与系统音频重叠)≈ 0.8;mic 先耗尽后尾区为纯系统音频 ≈ 0.5
        // 重采样(44.1k→48k)在首尾有滤波器边缘效应,中间帧应精确等于 0.8
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
        for i in stride(from: 100 * 2, to: totalSamples - 100 * 2, by: 1) {
            let v = outputFrames[i]
            if abs(v - 0.8) > 0.01 {
                return "mid-frame value mismatch at frame \(i / 2) ch\(i % 2): got \(v), want ~0.8"
            }
        }

        // 积压上限测试:先推 0.5s 系统音频(无 mic,直接输出、数组残留),再推 6 秒麦克风。
        // 覆盖"另一路曾输出后停止"场景(旧 isEmpty 判定在此场景失效,CI 可拦截回归)。
        guard let shortSys = makeTestCMSampleBuffer(
            sampleRate: 48_000, channels: 2, seconds: 0.5, leftValue: 0.5, rightValue: 0.5
        ) else { return "failed to build short sys buffer" }
        guard let longMic = makeTestCMSampleBuffer(
            sampleRate: 48_000, channels: 2, seconds: 6.0, leftValue: 0.3, rightValue: 0.3
        ) else { return "failed to build long mic buffer" }
        let m2 = AudioMixer()
        m2.push(shortSys, isMicrophone: false)
        m2.push(longMic, isMicrophone: true)
        let state = m2.debugDescription
        // 6 秒数据(576000 Float)超过 5 秒上限(480000),丢弃最老 48000 帧:start=48000 count=480000
        if !state.contains("mic(start=48000 count=480000") {
            return "backlog cap not applied: \(state)"
        }
        return nil
    }
}

/// 构造测试用 CMSampleBuffer:交错 Float32,常量值信号。
/// 注意:用交错格式(CMAudioSampleBufferCreateWithPacketDescriptions 对 non-interleaved
/// PCM 的包大小计算有怪癖,会按声道数重复展开;真实 SCStream buffer 由
/// CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer 解析,不受影响)。
private func makeTestCMSampleBuffer(
    sampleRate: Double, channels: UInt32, seconds: Double, leftValue: Float, rightValue: Float
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
        presentationTimeStamp: .zero,
        packetDescriptions: nil,
        sampleBufferOut: &sb
    ) == noErr else { return nil }
    return sb
}
