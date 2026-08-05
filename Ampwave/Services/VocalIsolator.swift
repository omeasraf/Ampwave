//
//  VocalIsolator.swift
//  Ampwave
//

import AVFoundation
import AudioToolbox

// MARK: - Biquad Filter

struct BiquadCoeffs {
    var b0, b1, b2, a1, a2: Float

    static var passthrough: BiquadCoeffs {
        BiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
    }

    /// Peaking EQ biquad coefficients (Audio EQ Cookbook, R. Zölzer).
    static func peaking(freq: Float, gainDB: Float, Q: Float, sampleRate: Float) -> BiquadCoeffs {
        guard gainDB != 0 else { return .passthrough }
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let sinW0 = sin(w0)
        let cosW0 = cos(w0)
        let alpha = sinW0 / (2.0 * Q)
        let a0inv: Float = 1.0 / (1.0 + alpha / A)
        return BiquadCoeffs(
            b0: (1.0 + alpha * A) * a0inv,
            b1: (-2.0 * cosW0)    * a0inv,
            b2: (1.0 - alpha * A) * a0inv,
            a1: (-2.0 * cosW0)    * a0inv,
            a2: (1.0 - alpha / A) * a0inv
        )
    }

    /// Low-pass biquad coefficients (Audio EQ Cookbook, R. Zölzer). Used to
    /// carve the sub-bass/kick fundamental out of the center channel before
    /// vocal-removal processing runs, so a center-panned kick/bass doesn't
    /// get hollowed out along with the vocal.
    static func lowpass(freq: Float, Q: Float, sampleRate: Float) -> BiquadCoeffs {
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let sinW0 = sin(w0)
        let cosW0 = cos(w0)
        let alpha = sinW0 / (2.0 * Q)
        let a0inv: Float = 1.0 / (1.0 + alpha)
        return BiquadCoeffs(
            b0: ((1.0 - cosW0) / 2.0) * a0inv,
            b1: (1.0 - cosW0)         * a0inv,
            b2: ((1.0 - cosW0) / 2.0) * a0inv,
            a1: (-2.0 * cosW0)        * a0inv,
            a2: (1.0 - alpha)         * a0inv
        )
    }
}

struct BiquadState {
    var x1: Float = 0, x2: Float = 0
    var y1: Float = 0, y2: Float = 0

    mutating func process(_ x: Float, _ c: BiquadCoeffs) -> Float {
        let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

// MARK: - VocalIsolator

final class VocalIsolator {

    static let shared = VocalIsolator()

    // Vocal isolation (shared with audio tap via raw pointers for lock-free access)
    private let targetVocalLevelPtr: UnsafeMutablePointer<Float>
    private let currentVocalLevelPtr: UnsafeMutablePointer<Float>

    // EQ: enabled flag + 10 gain values
    private let eqEnabledPtr: UnsafeMutablePointer<Bool>
    private let eqGainsPtr: UnsafeMutablePointer<Float>   // capacity: 10

    private let bandCount = 10
    private let bandFreqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private let bandQ: Float = 1.41

    // Bass protection for vocal removal: below this frequency, the center
    // channel is left partly alone so kick/bass keep their weight instead of
    // getting hollowed out along with the vocal.
    //
    // Kept deliberately low. The filter is only 12 dB/oct, so a crossover set
    // anywhere near vocal territory still leaks a lot of vocal energy into the
    // protected path — at 180 Hz that audibly weakened vocal removal. 90 Hz
    // sits under essentially every sung fundamental while still covering the
    // kick and bass fundamentals that carry the low end.
    private let bassProtectFreq: Float = 90.0
    private let bassProtectQ: Float = 0.707
    /// 0 = bass ducks exactly like the rest of the center channel (original
    /// behavior), 1 = bass level never changes regardless of vocal removal.
    private let bassProtectAmount: Float = 0.6

    var vocalLevel: Float {
        get { targetVocalLevelPtr.pointee }
        set {
            let clamped = min(max(newValue, 0.0), 1.0)
            targetVocalLevelPtr.pointee = clamped
        }
    }

    func setEQEnabled(_ enabled: Bool) {
        eqEnabledPtr.pointee = enabled
    }

    func setEQGain(_ gain: Float, atBand band: Int) {
        guard band >= 0 && band < bandCount else { return }
        eqGainsPtr[band] = min(max(gain, -12.0), 12.0)
    }

    private init() {
        targetVocalLevelPtr = .allocate(capacity: 1)
        currentVocalLevelPtr = .allocate(capacity: 1)
        eqEnabledPtr = .allocate(capacity: 1)
        eqGainsPtr = .allocate(capacity: 10)

        targetVocalLevelPtr.pointee = 1.0
        currentVocalLevelPtr.pointee = 1.0
        eqEnabledPtr.pointee = false
        eqGainsPtr.initialize(repeating: 0, count: 10)
    }

    deinit {
        targetVocalLevelPtr.deallocate()
        currentVocalLevelPtr.deallocate()
        eqEnabledPtr.deallocate()
        eqGainsPtr.deallocate()
    }

    // MARK: - Tap Storage

    final class TapStorage {
        let targetLevel: UnsafeMutablePointer<Float>
        let currentLevel: UnsafeMutablePointer<Float>

        // EQ
        let eqEnabled: UnsafeMutablePointer<Bool>
        let eqGains: UnsafeMutablePointer<Float>   // 10 bands
        let bandFreqs: [Float]
        let bandQ: Float

        // Per-channel biquad states: [band][0=L, 1=R]
        var eqState: [[BiquadState]]
        var eqCoeffs: [BiquadCoeffs]
        var lastGains: [Float]
        var sampleRate: Float = 44100.0

        // Bass-protection split (mid channel only, ahead of vocal removal)
        let bassProtectFreq: Float
        let bassProtectQ: Float
        let bassProtectAmount: Float
        var bassState = BiquadState()
        var bassCoeffs: BiquadCoeffs = .passthrough
        /// False until `prepare` computes real coefficients for the actual
        /// sample rate. Guards against the identity default being used as a
        /// low-pass, which would silently defeat vocal removal entirely.
        var bassReady = false

        // Apple ships a neural voice-isolation Audio Unit on iOS 16/macOS 13
        // and later. Unlike mid/side cancellation, it can identify vocals that
        // are doubled, reverberant, or spread across the stereo field.
        //
        // The unit has look-ahead latency. MTAudioProcessingTap requires the
        // caller to absorb that latency, so source audio is read ahead and the
        // dry signal is kept in this ring until the matching isolated-vocal
        // frames are available. The returned audio therefore stays aligned to
        // the asset timeline and to the synced lyrics.
        #if !os(visionOS)
        var soundIsolationUnit: AudioUnit?
        var isolatedVoiceBuffer: AVAudioPCMBuffer?
        var processedOutputBuffer: AVAudioPCMBuffer?
        var sourceBuffer: AVAudioPCMBuffer?
        var silenceBuffer: AVAudioPCMBuffer?
        var currentNativeInput: UnsafeMutablePointer<AudioBufferList>?
        var nativeLatencyFrames = 0
        var nativePrimingFrames = 0
        var nativeSampleTime: Float64 = 0
        var nativeReady = false
        var nativeStreamActivated = false
        #endif

        var dryLeft: [Float] = []
        var dryRight: [Float] = []
        var dryReadIndex = 0
        var dryWriteIndex = 0
        var dryFrameCount = 0
        var sourceEnded = false
        var outputStartPending = true

        var frameCounter: Int64 = 0

        init(
            targetLevel: UnsafeMutablePointer<Float>,
            currentLevel: UnsafeMutablePointer<Float>,
            eqEnabled: UnsafeMutablePointer<Bool>,
            eqGains: UnsafeMutablePointer<Float>,
            bandFreqs: [Float],
            bandQ: Float,
            bassProtectFreq: Float,
            bassProtectQ: Float,
            bassProtectAmount: Float
        ) {
            self.targetLevel = targetLevel
            self.currentLevel = currentLevel
            self.eqEnabled = eqEnabled
            self.eqGains = eqGains
            self.bandFreqs = bandFreqs
            self.bandQ = bandQ
            self.bassProtectFreq = bassProtectFreq
            self.bassProtectQ = bassProtectQ
            self.bassProtectAmount = bassProtectAmount
            let n = bandFreqs.count
            self.eqState = Array(repeating: Array(repeating: BiquadState(), count: 2), count: n)
            self.eqCoeffs = Array(repeating: .passthrough, count: n)
            self.lastGains = Array(repeating: 0, count: n)
        }

        deinit {
            tearDownNativeVoiceIsolation()
        }

        func recomputeCoeffsIfNeeded() {
            var changed = false
            for i in 0..<bandFreqs.count {
                let g = eqGains[i]
                if g != lastGains[i] {
                    lastGains[i] = g
                    changed = true
                }
            }
            guard changed else { return }
            for i in 0..<bandFreqs.count {
                eqCoeffs[i] = .peaking(freq: bandFreqs[i], gainDB: lastGains[i], Q: bandQ, sampleRate: sampleRate)
            }
        }

        func applyEQ(left: inout Float, right: inout Float) {
            for i in 0..<eqCoeffs.count {
                left  = eqState[i][0].process(left,  eqCoeffs[i])
                right = eqState[i][1].process(right, eqCoeffs[i])
            }
        }

        func resetFilterState() {
            for band in eqState.indices {
                for channel in eqState[band].indices {
                    eqState[band][channel] = BiquadState()
                }
            }
            bassState = BiquadState()
        }

        // MARK: Native voice separation

        func prepareNativeVoiceIsolation(
            maxFrames: CMItemCount,
            processingFormat: UnsafePointer<AudioStreamBasicDescription>
        ) {
            tearDownNativeVoiceIsolation()

            #if !os(visionOS)
            guard maxFrames > 0 else { return }

            let incomingFormat = processingFormat.pointee
            guard incomingFormat.mFormatID == kAudioFormatLinearPCM,
                  incomingFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  incomingFormat.mBitsPerChannel == 32,
                  incomingFormat.mChannelsPerFrame == 2
            else { return }

            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_AUSoundIsolation,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &description) else { return }

            var newUnit: AudioUnit?
            guard AudioComponentInstanceNew(component, &newUnit) == noErr,
                  let unit = newUnit
            else { return }

            soundIsolationUnit = unit
            var format = incomingFormat
            let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard
                AudioUnitSetProperty(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    &format,
                    formatSize
                ) == noErr,
                AudioUnitSetProperty(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    0,
                    &format,
                    formatSize
                ) == noErr
            else {
                tearDownNativeVoiceIsolation()
                return
            }

            var maximumFrames = UInt32(maxFrames)
            guard AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &maximumFrames,
                UInt32(MemoryLayout<UInt32>.size)
            ) == noErr else {
                tearDownNativeVoiceIsolation()
                return
            }

            var inputCallback = AURenderCallbackStruct(
                inputProc: { refCon, _, _, _, frameCount, ioData in
                    guard let ioData else { return kAudio_ParamError }
                    let storage = Unmanaged<TapStorage>
                        .fromOpaque(refCon)
                        .takeUnretainedValue()
                    return storage.supplyNativeInput(frameCount: frameCount, ioData: ioData)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            guard AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &inputCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ) == noErr else {
                tearDownNativeVoiceIsolation()
                return
            }

            guard
                AudioUnitSetParameter(
                    unit,
                    kAUSoundIsolationParam_WetDryMixPercent,
                    kAudioUnitScope_Global,
                    0,
                    100,
                    0
                ) == noErr,
                AudioUnitSetParameter(
                    unit,
                    kAUSoundIsolationParam_SoundToIsolate,
                    kAudioUnitScope_Global,
                    0,
                    Float(kAUSoundIsolationSoundType_HighQualityVoice),
                    0
                ) == noErr,
                AudioUnitInitialize(unit) == noErr
            else {
                tearDownNativeVoiceIsolation()
                return
            }

            guard let audioFormat = AVAudioFormat(streamDescription: &format),
                  let isolated = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(maximumFrames)
                  ),
                  let processedOutput = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(maximumFrames)
                  ),
                  let source = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(maximumFrames)
                  ),
                  let silence = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(maximumFrames)
                  )
            else {
                tearDownNativeVoiceIsolation()
                return
            }

            var latency: Float64 = 0
            var latencySize = UInt32(MemoryLayout<Float64>.size)
            guard AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_Latency,
                kAudioUnitScope_Global,
                0,
                &latency,
                &latencySize
            ) == noErr else {
                tearDownNativeVoiceIsolation()
                return
            }

            isolatedVoiceBuffer = isolated
            processedOutputBuffer = processedOutput
            sourceBuffer = source
            silenceBuffer = silence
            nativeLatencyFrames = max(0, Int((latency * format.mSampleRate).rounded()))

            // The ring can temporarily contain the entire look-ahead plus one
            // render slice while the Audio Unit is being primed.
            let ringCapacity = max(1, nativeLatencyFrames + Int(maximumFrames) + 1)
            dryLeft = Array(repeating: 0, count: ringCapacity)
            dryRight = Array(repeating: 0, count: ringCapacity)
            nativeReady = true
            resetNativeStream()
            #endif
        }

        func tearDownNativeVoiceIsolation() {
            #if !os(visionOS)
            if let unit = soundIsolationUnit {
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
            soundIsolationUnit = nil
            isolatedVoiceBuffer = nil
            processedOutputBuffer = nil
            sourceBuffer = nil
            silenceBuffer = nil
            currentNativeInput = nil
            nativeLatencyFrames = 0
            nativePrimingFrames = 0
            nativeSampleTime = 0
            nativeReady = false
            nativeStreamActivated = false
            #endif

            dryLeft.removeAll(keepingCapacity: false)
            dryRight.removeAll(keepingCapacity: false)
            dryReadIndex = 0
            dryWriteIndex = 0
            dryFrameCount = 0
            sourceEnded = false
            outputStartPending = true
        }

        func resetNativeStream() {
            #if !os(visionOS)
            guard nativeReady, let unit = soundIsolationUnit else { return }
            AudioUnitReset(unit, kAudioUnitScope_Global, 0)
            nativePrimingFrames = nativeLatencyFrames
            nativeSampleTime = 0
            #else
            return
            #endif

            dryReadIndex = 0
            dryWriteIndex = 0
            dryFrameCount = 0
            sourceEnded = false
            outputStartPending = true
            resetFilterState()
        }

        #if !os(visionOS)
        func supplyNativeInput(
            frameCount: UInt32,
            ioData: UnsafeMutablePointer<AudioBufferList>
        ) -> OSStatus {
            guard let input = currentNativeInput else {
                return kAudioUnitErr_NoConnection
            }

            let source = UnsafeMutableAudioBufferListPointer(input)
            let destination = UnsafeMutableAudioBufferListPointer(ioData)
            guard source.count == destination.count else {
                return kAudioUnitErr_FormatNotSupported
            }

            for index in 0..<source.count {
                let sourceBuffer = source[index]
                let byteCount = min(
                    sourceBuffer.mDataByteSize,
                    destination[index].mDataByteSize
                )
                destination[index].mNumberChannels = sourceBuffer.mNumberChannels
                destination[index].mDataByteSize = byteCount

                if let destinationData = destination[index].mData,
                   let sourceData = sourceBuffer.mData
                {
                    memcpy(destinationData, sourceData, Int(byteCount))
                } else {
                    destination[index].mData = sourceBuffer.mData
                    destination[index].mDataByteSize = sourceBuffer.mDataByteSize
                }
            }
            return noErr
        }
        #endif

        func pushDryAudio(from bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
            guard frameCount > 0, !dryLeft.isEmpty else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

            if buffers.count == 1,
               buffers[0].mNumberChannels == 2,
               let data = buffers[0].mData?.assumingMemoryBound(to: Float.self)
            {
                for frame in 0..<frameCount {
                    dryLeft[dryWriteIndex] = data[frame * 2]
                    dryRight[dryWriteIndex] = data[frame * 2 + 1]
                    advanceDryWriteIndex()
                }
            } else if buffers.count >= 2,
                      let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            {
                for frame in 0..<frameCount {
                    dryLeft[dryWriteIndex] = left[frame]
                    dryRight[dryWriteIndex] = right[frame]
                    advanceDryWriteIndex()
                }
            }
        }

        private func advanceDryWriteIndex() {
            dryWriteIndex += 1
            if dryWriteIndex == dryLeft.count { dryWriteIndex = 0 }
            if dryFrameCount < dryLeft.count {
                dryFrameCount += 1
            } else {
                // Defensive only: the ring is sized so normal look-ahead can
                // never overwrite unread frames.
                dryReadIndex = dryWriteIndex
            }
        }

        private func popDryAudio() -> (Float, Float)? {
            guard dryFrameCount > 0 else { return nil }
            let result = (dryLeft[dryReadIndex], dryRight[dryReadIndex])
            dryReadIndex += 1
            if dryReadIndex == dryLeft.count { dryReadIndex = 0 }
            dryFrameCount -= 1
            return result
        }

        func renderNativeVoice(
            input: UnsafeMutablePointer<AudioBufferList>,
            frameCount: UInt32,
            outputBuffer: AVAudioPCMBuffer,
            outputOffset: inout Int,
            outputLimit: Int
        ) -> Bool {
            #if os(visionOS)
            return false
            #else
            guard nativeReady,
                  let unit = soundIsolationUnit,
                  let isolatedVoiceBuffer
            else { return false }

            isolatedVoiceBuffer.frameLength = frameCount
            currentNativeInput = input

            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = nativeSampleTime
            timestamp.mFlags = .sampleTimeValid
            var actionFlags: AudioUnitRenderActionFlags = []
            let status = AudioUnitRender(
                unit,
                &actionFlags,
                &timestamp,
                0,
                frameCount,
                isolatedVoiceBuffer.mutableAudioBufferList
            )
            currentNativeInput = nil
            guard status == noErr else { return false }

            nativeSampleTime += Float64(frameCount)
            let isolatedBuffers = UnsafeMutableAudioBufferListPointer(
                isolatedVoiceBuffer.mutableAudioBufferList
            )
            let destination = UnsafeMutableAudioBufferListPointer(
                outputBuffer.mutableAudioBufferList
            )

            let skipCount = min(nativePrimingFrames, Int(frameCount))
            nativePrimingFrames -= skipCount
            guard skipCount < Int(frameCount) else { return true }

            for frame in skipCount..<Int(frameCount) {
                guard outputOffset < outputLimit, let dry = popDryAudio() else { break }

                let isolated: (Float, Float)
                if isolatedBuffers.count == 1,
                   isolatedBuffers[0].mNumberChannels == 2,
                   let data = isolatedBuffers[0].mData?.assumingMemoryBound(to: Float.self)
                {
                    isolated = (data[frame * 2], data[frame * 2 + 1])
                } else if isolatedBuffers.count >= 2,
                          let left = isolatedBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                          let right = isolatedBuffers[1].mData?.assumingMemoryBound(to: Float.self)
                {
                    isolated = (left[frame], right[frame])
                } else {
                    return false
                }

                var left = dry.0
                var right = dry.1
                applyNativeVocalLevel(
                    left: &left,
                    right: &right,
                    isolatedLeft: isolated.0,
                    isolatedRight: isolated.1
                )
                if eqEnabled.pointee { applyEQ(left: &left, right: &right) }

                if destination.count == 1,
                   destination[0].mNumberChannels == 2,
                   let data = destination[0].mData?.assumingMemoryBound(to: Float.self)
                {
                    data[outputOffset * 2] = left
                    data[outputOffset * 2 + 1] = right
                } else if destination.count >= 2,
                          let leftData = destination[0].mData?.assumingMemoryBound(to: Float.self),
                          let rightData = destination[1].mData?.assumingMemoryBound(to: Float.self)
                {
                    leftData[outputOffset] = left
                    rightData[outputOffset] = right
                } else {
                    return false
                }
                outputOffset += 1
            }
            return true
            #endif
        }

        private func applyNativeVocalLevel(
            left: inout Float,
            right: inout Float,
            isolatedLeft: Float,
            isolatedRight: Float
        ) {
            let target = targetLevel.pointee
            var current = currentLevel.pointee
            current += (target - current) * 0.015

            // Equal-power-ish curve, matching the feel of Apple Music Sing:
            // the top of the control is subtle while the bottom has enough
            // travel to let the listener take the lead.
            let vocalGain = pow(sin(min(max(current, 0), 1) * .pi * 0.5), 1.35)
            let removalAmount = 1 - vocalGain
            left -= isolatedLeft * removalAmount
            right -= isolatedRight * removalAmount
            currentLevel.pointee = current
        }

        func processWithNativeVoiceIsolation(
            tap: MTAudioProcessingTap,
            requestedFrames: CMItemCount,
            inputFlags: MTAudioProcessingTapFlags,
            outputList: UnsafeMutablePointer<AudioBufferList>,
            framesOut: UnsafeMutablePointer<CMItemCount>?,
            flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>?
        ) -> Bool {
            #if os(visionOS)
            return false
            #else
            guard nativeReady,
                  let sourceBuffer,
                  let silenceBuffer,
                  let processedOutputBuffer,
                  requestedFrames > 0
            else { return false }

            // Avoid running the neural model for ordinary playback. Once the
            // listener lowers the vocal level we keep it active for the rest
            // of the stream because it has already read ahead by its latency.
            let wantsVocalAdjustment =
                targetLevel.pointee < 0.999 || currentLevel.pointee < 0.999
            guard nativeStreamActivated || wantsVocalAdjustment else { return false }
            if !nativeStreamActivated {
                resetNativeStream()
                nativeStreamActivated = true
                // Turning the control on mid-song is not a source
                // discontinuity and must not reset AVPlayer's timeline.
                outputStartPending = false
            }

            if inputFlags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
                resetNativeStream()
            }
            if eqEnabled.pointee { recomputeCoeffsIfNeeded() }

            let requested = Int(requestedFrames)
            processedOutputBuffer.frameLength = AVAudioFrameCount(requested)
            var produced = 0
            var outputFlags: MTAudioProcessingTapFlags = 0

            while produced < requested {
                if !sourceEnded {
                    let framesNeeded = nativePrimingFrames + (requested - produced)
                    let fetchCount = min(Int(sourceBuffer.frameCapacity), max(1, framesNeeded))
                    sourceBuffer.frameLength = AVAudioFrameCount(fetchCount)

                    var sourceFlags: MTAudioProcessingTapFlags = 0
                    var fetched: CMItemCount = 0
                    let status = MTAudioProcessingTapGetSourceAudio(
                        tap,
                        CMItemCount(fetchCount),
                        sourceBuffer.mutableAudioBufferList,
                        &sourceFlags,
                        nil,
                        &fetched
                    )
                    guard status == noErr else { return false }

                    if sourceFlags & kMTAudioProcessingTapFlag_StartOfStream != 0,
                       !outputStartPending
                    {
                        resetNativeStream()
                    }
                    if sourceFlags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
                        outputStartPending = true
                    }

                    if fetched > 0 {
                        sourceBuffer.frameLength = AVAudioFrameCount(fetched)
                        pushDryAudio(
                            from: sourceBuffer.mutableAudioBufferList,
                            frameCount: Int(fetched)
                        )
                        guard renderNativeVoice(
                            input: sourceBuffer.mutableAudioBufferList,
                            frameCount: UInt32(fetched),
                            outputBuffer: processedOutputBuffer,
                            outputOffset: &produced,
                            outputLimit: requested
                        ) else { return false }
                    }

                    if sourceFlags & kMTAudioProcessingTapFlag_EndOfStream != 0
                        || fetched < CMItemCount(fetchCount)
                    {
                        sourceEnded = true
                    }
                    if fetched == 0 && !sourceEnded {
                        sourceEnded = true
                    }
                } else if dryFrameCount > 0 {
                    // Flush the Audio Unit's look-ahead with silence. These
                    // frames are never added to the dry queue, so output ends
                    // at exactly the original asset length.
                    let flushCount = min(
                        Int(silenceBuffer.frameCapacity),
                        max(1, nativePrimingFrames + (requested - produced))
                    )
                    silenceBuffer.frameLength = AVAudioFrameCount(flushCount)
                    let silenceList = UnsafeMutableAudioBufferListPointer(
                        silenceBuffer.mutableAudioBufferList
                    )
                    for buffer in silenceList {
                        if let data = buffer.mData {
                            memset(data, 0, Int(buffer.mDataByteSize))
                        }
                    }
                    guard renderNativeVoice(
                        input: silenceBuffer.mutableAudioBufferList,
                        frameCount: UInt32(flushCount),
                        outputBuffer: processedOutputBuffer,
                        outputOffset: &produced,
                        outputLimit: requested
                    ) else { return false }
                } else {
                    break
                }
            }

            processedOutputBuffer.frameLength = AVAudioFrameCount(produced)
            copyAudio(
                from: processedOutputBuffer.mutableAudioBufferList,
                to: outputList
            )
            framesOut?.pointee = CMItemCount(produced)

            if outputStartPending {
                outputFlags |= kMTAudioProcessingTapFlag_StartOfStream
                outputStartPending = false
            }
            if sourceEnded && dryFrameCount == 0 {
                outputFlags |= kMTAudioProcessingTapFlag_EndOfStream
            }
            flagsOut?.pointee = outputFlags
            return true
            #endif
        }

        private func copyAudio(
            from sourceList: UnsafeMutablePointer<AudioBufferList>,
            to destinationList: UnsafeMutablePointer<AudioBufferList>
        ) {
            let source = UnsafeMutableAudioBufferListPointer(sourceList)
            let destination = UnsafeMutableAudioBufferListPointer(destinationList)
            guard source.count == destination.count else { return }

            for index in 0..<source.count {
                destination[index].mNumberChannels = source[index].mNumberChannels
                destination[index].mDataByteSize = source[index].mDataByteSize
                if let destinationData = destination[index].mData,
                   let sourceData = source[index].mData
                {
                    memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
                } else {
                    destination[index].mData = source[index].mData
                }
            }
        }
    }

    // MARK: - AVAudioMix Factory

    func createAudioMix(for audioTrack: AVAssetTrack) -> AVAudioMix? {
        let storage = TapStorage(
            targetLevel: targetVocalLevelPtr,
            currentLevel: currentVocalLevelPtr,
            eqEnabled: eqEnabledPtr,
            eqGains: eqGainsPtr,
            bandFreqs: bandFreqs,
            bandQ: bandQ,
            bassProtectFreq: bassProtectFreq,
            bassProtectQ: bassProtectQ,
            bassProtectAmount: bassProtectAmount
        )

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(storage).toOpaque()),

            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },

            finalize: { tap in
                Unmanaged<TapStorage>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .release()
            },

            prepare: { tap, maxFrames, processingFormat in
                let storage = Unmanaged<TapStorage>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                storage.sampleRate = Float(processingFormat.pointee.mSampleRate)
                // Pre-compute coefficients at actual sample rate
                for i in 0..<storage.bandFreqs.count {
                    storage.lastGains[i] = storage.eqGains[i]
                    storage.eqCoeffs[i] = .peaking(
                        freq: storage.bandFreqs[i],
                        gainDB: storage.lastGains[i],
                        Q: storage.bandQ,
                        sampleRate: storage.sampleRate
                    )
                }
                storage.bassCoeffs = .lowpass(
                    freq: storage.bassProtectFreq,
                    Q: storage.bassProtectQ,
                    sampleRate: storage.sampleRate
                )
                storage.bassReady = true
                storage.prepareNativeVoiceIsolation(
                    maxFrames: maxFrames,
                    processingFormat: processingFormat
                )
            },

            unprepare: { tap in
                let storage = Unmanaged<TapStorage>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                storage.tearDownNativeVoiceIsolation()
            },

            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let storage = Unmanaged<TapStorage>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()

                // Prefer Apple's neural voice separator. It is what makes the
                // control work on modern stereo mixes where the vocal isn't a
                // single center-panned signal. Vision Pro and any unexpected
                // unsupported format keep the deterministic mid/side path.
                if storage.processWithNativeVoiceIsolation(
                    tap: tap,
                    requestedFrames: numberFrames,
                    inputFlags: flags,
                    outputList: bufferListInOut,
                    framesOut: numberFramesOut,
                    flagsOut: flagsOut
                ) {
                    return
                }

                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }

                if flags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
                    storage.resetFilterState()
                }

                let target = storage.targetLevel.pointee
                var current = storage.currentLevel.pointee
                let doVocal = !(target >= 0.999 && current >= 0.999)
                let doEQ = storage.eqEnabled.pointee

                // Recompute EQ coefficients if gains changed
                if doEQ { storage.recomputeCoeffsIfNeeded() }

                let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                let ramp: Float = 0.015

                func vocalCurve(_ v: Float) -> Float {
                    pow(sin(min(max(v, 0), 1) * .pi * 0.5), 1.35)
                }

                if buffers.count == 1 {
                    guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                    let ch = Int(buffers[0].mNumberChannels)
                    guard ch == 2 else { return }

                    for i in 0..<Int(numberFrames) {
                        var L = data[i * 2]
                        var R = data[i * 2 + 1]

                        if doVocal {
                            current += (target - current) * ramp
                            let s = vocalCurve(current)
                            let k1 = (s + 1.0) / 2.0
                            let k2 = (s - 1.35) / 2.0

                            // Mid/side decomposition: k1+k2 is the gain applied
                            // to the center (mid) channel, k1-k2 the constant
                            // side-channel width boost. Vocal removal is really
                            // "attenuate the center", but a center-panned
                            // kick/bass gets caught in that same net.
                            let midGain = k1 + k2
                            let sideGain = k1 - k2
                            let mid = (L + R) * 0.5
                            let side = (L - R) * 0.5

                            // Split only the very low end back out of mid and
                            // hold it nearer unity, so the kick/bass keeps its
                            // weight while everything above it — including the
                            // whole vocal range — still gets full cancellation.
                            // Skipped until `prepare` has supplied real
                            // coefficients: the identity default would make
                            // lowMid == mid, routing the *entire* center
                            // channel through bassGain and all but disabling
                            // vocal removal.
                            var newMid = mid * midGain
                            if storage.bassReady {
                                let lowMid = storage.bassState.process(mid, storage.bassCoeffs)
                                let highMid = mid - lowMid
                                let bassGain =
                                    1.0 + (midGain - 1.0) * (1.0 - storage.bassProtectAmount)
                                newMid = lowMid * bassGain + highMid * midGain
                            }
                            let newSide = side * sideGain

                            L = newMid + newSide
                            R = newMid - newSide
                        }

                        if doEQ { storage.applyEQ(left: &L, right: &R) }

                        data[i * 2]     = L
                        data[i * 2 + 1] = R
                    }

                } else if buffers.count >= 2 {
                    guard
                        let lData = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                        let rData = buffers[1].mData?.assumingMemoryBound(to: Float.self)
                    else { return }

                    for i in 0..<Int(numberFrames) {
                        var L = lData[i]
                        var R = rData[i]

                        if doVocal {
                            current += (target - current) * ramp
                            let s = vocalCurve(current)
                            let k1 = (s + 1.0) / 2.0
                            let k2 = (s - 1.35) / 2.0

                            // Mid/side decomposition: k1+k2 is the gain applied
                            // to the center (mid) channel, k1-k2 the constant
                            // side-channel width boost. Vocal removal is really
                            // "attenuate the center", but a center-panned
                            // kick/bass gets caught in that same net.
                            let midGain = k1 + k2
                            let sideGain = k1 - k2
                            let mid = (L + R) * 0.5
                            let side = (L - R) * 0.5

                            // Split only the very low end back out of mid and
                            // hold it nearer unity, so the kick/bass keeps its
                            // weight while everything above it — including the
                            // whole vocal range — still gets full cancellation.
                            // Skipped until `prepare` has supplied real
                            // coefficients: the identity default would make
                            // lowMid == mid, routing the *entire* center
                            // channel through bassGain and all but disabling
                            // vocal removal.
                            var newMid = mid * midGain
                            if storage.bassReady {
                                let lowMid = storage.bassState.process(mid, storage.bassCoeffs)
                                let highMid = mid - lowMid
                                let bassGain =
                                    1.0 + (midGain - 1.0) * (1.0 - storage.bassProtectAmount)
                                newMid = lowMid * bassGain + highMid * midGain
                            }
                            let newSide = side * sideGain

                            L = newMid + newSide
                            R = newMid - newSide
                        }

                        if doEQ { storage.applyEQ(left: &L, right: &R) }

                        lData[i] = L
                        rData[i] = R
                    }
                }

                storage.currentLevel.pointee = current
                storage.frameCounter += Int64(numberFrames)
            }
        )

        var tap: MTAudioProcessingTap?
        let createStatus = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap)

        guard createStatus == noErr, let tap = tap else {
            print("[ERROR] VocalIsolator: Failed to create tap: \(createStatus)")
            Unmanaged.passUnretained(storage).release()
            return nil
        }

        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.audioTapProcessor = tap

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        return audioMix
    }
}
