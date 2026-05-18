//
//  VocalIsolator.swift
//  Ampwave
//
//  Created by Ome Asraf on 5/9/26.
//


//
//  VocalIsolator.swift
//  Ampwave
//
//  Created by Ome Asraf on 5/8/26.
//
import AVFoundation
import AudioToolbox

final class VocalIsolator {
    
    static let shared = VocalIsolator()
    
    private let targetVocalLevelPtr: UnsafeMutablePointer<Float>
    private let currentVocalLevelPtr: UnsafeMutablePointer<Float>
    
    var vocalLevel: Float {
        get { targetVocalLevelPtr.pointee }
        set {
            let clamped = min(max(newValue, 0.0), 1.0)
            targetVocalLevelPtr.pointee = clamped
            print("[UI] vocalLevel = \(clamped)")
        }
    }
    
    private init() {
        targetVocalLevelPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        currentVocalLevelPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        
        targetVocalLevelPtr.pointee = 1.0
        currentVocalLevelPtr.pointee = 1.0
    }
    
    deinit {
        targetVocalLevelPtr.deallocate()
        currentVocalLevelPtr.deallocate()
    }
    
    final class TapStorage {
        
        let targetLevel: UnsafeMutablePointer<Float>
        let currentLevel: UnsafeMutablePointer<Float>
        
        var frameCounter: Int64 = 0
        
        init(
            targetLevel: UnsafeMutablePointer<Float>,
            currentLevel: UnsafeMutablePointer<Float>
        ) {
            self.targetLevel = targetLevel
            self.currentLevel = currentLevel
        }
    }
    
    func createAudioMix(for audioTrack: AVAssetTrack) -> AVAudioMix? {
        
        let storage = TapStorage(
            targetLevel: targetVocalLevelPtr,
            currentLevel: currentVocalLevelPtr
        )
        
        print("[VALIDATION] VocalIsolator: Creating tap for track \(audioTrack.trackID)")
        
        var callbacks = MTAudioProcessingTapCallbacks(
            
            version: kMTAudioProcessingTapCallbacksVersion_0,
            
            clientInfo: UnsafeMutableRawPointer(
                Unmanaged.passRetained(storage).toOpaque()
            ),
            
            init: { _, clientInfo, tapStorageOut in
                print("[VALIDATION] VocalIsolator: Tap init triggered")
                tapStorageOut.pointee = clientInfo
            },
            
            finalize: { tap in
                print("[VALIDATION] VocalIsolator: Tap finalize triggered")
                
                let storagePtr = MTAudioProcessingTapGetStorage(tap)
                
                Unmanaged<TapStorage>
                    .fromOpaque(storagePtr)
                    .release()
            },
            
            prepare: nil,
            unprepare: nil,
            
            process: {
                tap,
                numberFrames,
                flags,
                bufferListInOut,
                numberFramesOut,
                flagsOut in
                
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    numberFrames,
                    bufferListInOut,
                    flagsOut,
                    nil,
                    numberFramesOut
                )
                
                guard status == noErr else { return }
                
                let storagePtr = MTAudioProcessingTapGetStorage(tap)
                
                let storage = Unmanaged<TapStorage>
                    .fromOpaque(storagePtr)
                    .takeUnretainedValue()
                
                let target = storage.targetLevel.pointee
                var current = storage.currentLevel.pointee
                
                let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                
                // smoother + more responsive
                let rampSpeed: Float = 0.015
                
                var sumSqBefore: Float = 0
                var sumSqAfter: Float = 0
                var sampleCount = 0
                
                let skipProcessing =
                target >= 0.999 &&
                current >= 0.999
                
                // IMPORTANT:
                // use SAME curve everywhere
                func vocalCurve(_ value: Float) -> Float {
                    
                    let clamped = min(max(value, 0.0), 1.0)
                    
                    // Apple Music-ish feel
                    return pow(
                        sin(clamped * .pi * 0.5),
                        1.35
                    )
                }
                
                if buffers.count == 1 {
                    
                    let buffer = buffers[0]
                    
                    guard
                        let data = buffer.mData?
                            .assumingMemoryBound(to: Float.self)
                    else { return }
                    
                    let numChannels = Int(buffer.mNumberChannels)
                    
                    if numChannels == 2 {
                        
                        for i in 0..<Int(numberFrames) {
                            
                            let L = data[i * 2]
                            let R = data[i * 2 + 1]
                            
                            if !skipProcessing {
                                
                                current += (target - current) * rampSpeed
                                
                                let s = vocalCurve(current)
                                
                                // stronger center cancellation
                                let k1 = (s + 1.0) / 2.0
                                let k2 = (s - 1.35) / 2.0
                                
                                let nL = k1 * L + k2 * R
                                let nR = k2 * L + k1 * R
                                
                                data[i * 2] = nL
                                data[i * 2 + 1] = nR
                                
                                sumSqBefore += (L * L + R * R)
                                sumSqAfter += (nL * nL + nR * nR)
                                
                                sampleCount += 2
                            }
                        }
                    }
                    
                } else if buffers.count >= 2 {
                    
                    guard
                        let leftData = buffers[0]
                            .mData?
                            .assumingMemoryBound(to: Float.self),
                        
                            let rightData = buffers[1]
                            .mData?
                            .assumingMemoryBound(to: Float.self)
                            
                    else { return }
                    
                    for i in 0..<Int(numberFrames) {
                        
                        let L = leftData[i]
                        let R = rightData[i]
                        
                        if !skipProcessing {
                            
                            current += (target - current) * rampSpeed
                            
                            let s = vocalCurve(current)
                            
                            let k1 = (s + 1.0) / 2.0
                            let k2 = (s - 1.35) / 2.0
                            
                            let nL = k1 * L + k2 * R
                            let nR = k2 * L + k1 * R
                            
                            leftData[i] = nL
                            rightData[i] = nR
                            
                            sumSqBefore += (L * L + R * R)
                            sumSqAfter += (nL * nL + nR * nR)
                            
                            sampleCount += 2
                        }
                    }
                }
                
                storage.currentLevel.pointee = current
                storage.frameCounter += Int64(numberFrames)
            }
        )
        
        var tap: MTAudioProcessingTap?
        
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        
        if status != noErr {
            
            print("[ERROR] VocalIsolator: Failed to create tap: \(status)")
            
            Unmanaged.passUnretained(storage).release()
            
            return nil
        }
        
        let inputParams = AVMutableAudioMixInputParameters(
            track: audioTrack
        )
        
        inputParams.audioTapProcessor = tap
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        
        return audioMix
    }
}