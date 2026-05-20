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

        var frameCounter: Int64 = 0

        init(
            targetLevel: UnsafeMutablePointer<Float>,
            currentLevel: UnsafeMutablePointer<Float>,
            eqEnabled: UnsafeMutablePointer<Bool>,
            eqGains: UnsafeMutablePointer<Float>,
            bandFreqs: [Float],
            bandQ: Float
        ) {
            self.targetLevel = targetLevel
            self.currentLevel = currentLevel
            self.eqEnabled = eqEnabled
            self.eqGains = eqGains
            self.bandFreqs = bandFreqs
            self.bandQ = bandQ
            let n = bandFreqs.count
            self.eqState = Array(repeating: Array(repeating: BiquadState(), count: 2), count: n)
            self.eqCoeffs = Array(repeating: .passthrough, count: n)
            self.lastGains = Array(repeating: 0, count: n)
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
    }

    // MARK: - AVAudioMix Factory

    func createAudioMix(for audioTrack: AVAssetTrack) -> AVAudioMix? {
        let storage = TapStorage(
            targetLevel: targetVocalLevelPtr,
            currentLevel: currentVocalLevelPtr,
            eqEnabled: eqEnabledPtr,
            eqGains: eqGainsPtr,
            bandFreqs: bandFreqs,
            bandQ: bandQ
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
            },

            unprepare: nil,

            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, _ in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, nil, nil, numberFramesOut)
                guard status == noErr else { return }

                let storage = Unmanaged<TapStorage>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()

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
                            let nL = k1 * L + k2 * R
                            let nR = k2 * L + k1 * R
                            L = nL; R = nR
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
                            let nL = k1 * L + k2 * R
                            let nR = k2 * L + k1 * R
                            L = nL; R = nR
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
