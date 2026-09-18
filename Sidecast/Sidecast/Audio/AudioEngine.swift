// タップ・集約デバイス・IOProc の生成と破棄。
// すべての Core Audio 操作は専用のシリアルキューで行う（デバイス消失時の tear down は約 14 秒ブロックする。PoC 5）。
// IOProc はリアルタイム安全: ロック・アロケーション・ログ・ObjC メッセージ送信を一切しない。

import Foundation
import CoreAudio
import Synchronization
import os

enum AudioEngineError: Error, CustomStringConvertible {
    case tapCreation(OSStatus)
    case aggregateCreation(OSStatus)
    case ioProcCreation(OSStatus)
    case start(OSStatus)
    var description: String {
        switch self {
        case .tapCreation(let s): return "タップ作成失敗 \(describe(s))"
        case .aggregateCreation(let s): return "集約デバイス作成失敗 \(describe(s))"
        case .ioProcCreation(let s): return "IOProc 作成失敗 \(describe(s))"
        case .start(let s): return "開始失敗 \(describe(s))"
        }
    }
}

final class AudioEngine: Sendable {
    /// UI スレッドと IOProc の間で共有する値。IOProc からは relaxed な atomic 操作のみ
    final class Shared: @unchecked Sendable {
        let gain = Atomic<Float>(1.0)
        let callbacks = Atomic<UInt64>(0)
        let peak = Atomic<Float>(0)
    }

    private struct State: Sendable {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID? = nil
        var processes: [AudioObjectID] = []
        var hdmiUID: String? = nil
        var isRunning: Bool { aggregateID != kAudioObjectUnknown }
    }

    private let shared = Shared()
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "org.takashick.Sidecast.AudioEngine", qos: .userInitiated)
    private let log = Logger(subsystem: "org.takashick.Sidecast", category: "AudioEngine")

    // MARK: 状態参照（どのスレッドからでも可）

    var isRunning: Bool { state.withLock { $0.isRunning } }
    var tappedProcesses: [AudioObjectID] { state.withLock { $0.processes } }
    var tappedHDMIUID: String? { state.withLock { $0.hdmiUID } }
    var callbackCount: UInt64 { shared.callbacks.load(ordering: .relaxed) }
    var gain: Float { shared.gain.load(ordering: .relaxed) }
    /// 直近の出力ピーク（読み出しでリセット）
    func takePeak() -> Float { shared.peak.exchange(0, ordering: .relaxed) }
    func setGain(_ g: Float) { shared.gain.store(max(0, min(1, g)), ordering: .relaxed) }

    // MARK: 構築・破棄（エンジンキューで直列実行）

    func build(processes: [AudioObjectID], hdmiUID: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.buildSync(processes: processes, hdmiUID: hdmiUID); c.resume() }
                catch { c.resume(throwing: error) }
            }
        }
    }

    func tearDown() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { self.tearDownSync(); c.resume() }
        }
    }

    private func buildSync(processes: [AudioObjectID], hdmiUID: String) throws {
        tearDownSync()
        var s = State()
        s.processes = processes
        s.hdmiUID = hdmiUID

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.name = "Sidecast tap"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var st = AudioHardwareCreateProcessTap(desc, &s.tapID)
        guard st == noErr else { throw AudioEngineError.tapCreation(st) }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sidecast",
            kAudioAggregateDeviceUIDKey: "org.takashick.Sidecast.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: hdmiUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: hdmiUID, kAudioSubDeviceDriftCompensationKey: false]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &s.aggregateID)
        guard st == noErr else {
            AudioHardwareDestroyProcessTap(s.tapID)
            throw AudioEngineError.aggregateCreation(st)
        }

        st = AudioDeviceCreateIOProcIDWithBlock(&s.ioProcID, s.aggregateID, nil, Self.makeIOBlock(shared: shared))
        guard st == noErr, let procID = s.ioProcID else {
            AudioHardwareDestroyAggregateDevice(s.aggregateID)
            AudioHardwareDestroyProcessTap(s.tapID)
            throw AudioEngineError.ioProcCreation(st)
        }
        st = AudioDeviceStart(s.aggregateID, procID)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(s.aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(s.aggregateID)
            AudioHardwareDestroyProcessTap(s.tapID)
            throw AudioEngineError.start(st)
        }
        state.withLock { $0 = s }
        log.info("built: tap \(s.tapID) agg \(s.aggregateID) procs \(processes) -> \(hdmiUID, privacy: .public)")
    }

    private func tearDownSync() {
        let s = state.withLock { st -> State in let old = st; st = State(); return old }
        guard s.isRunning || s.tapID != kAudioObjectUnknown else { return }
        if let p = s.ioProcID, s.aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(s.aggregateID, p)
            AudioDeviceDestroyIOProcID(s.aggregateID, p)
        }
        if s.aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(s.aggregateID) }
        if s.tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(s.tapID) }
        log.info("torn down: tap \(s.tapID) agg \(s.aggregateID)")
    }

    // MARK: IOProc

    /// トップレベル/MainActor 文脈での推論を避けるため nonisolated static で生成する（PoC 2 の SIGTRAP 対策）
    nonisolated private static func makeIOBlock(shared: Shared) -> AudioDeviceIOBlock {
        return { _, inInputData, _, outOutputData, _ in
            shared.callbacks.wrappingAdd(1, ordering: .relaxed)
            let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
            let g = shared.gain.load(ordering: .relaxed)
            var peak: Float = 0

            guard let inBuf = inBuffers.first, let inData = inBuf.mData, inBuf.mNumberChannels > 0 else {
                for ob in outBuffers { if let d = ob.mData { memset(d, 0, Int(ob.mDataByteSize)) } }
                return
            }
            let inCh = Int(inBuf.mNumberChannels)
            let inS = inData.assumingMemoryBound(to: Float.self)
            let nIn = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size / inCh

            for ob in outBuffers {
                guard let outData = ob.mData, ob.mNumberChannels > 0 else { continue }
                let outCh = Int(ob.mNumberChannels)
                let out = outData.assumingMemoryBound(to: Float.self)
                let nOut = Int(ob.mDataByteSize) / MemoryLayout<Float>.size / outCh
                let n = min(nIn, nOut)
                for f in 0..<n {
                    for c in 0..<outCh {
                        // 出力チャンネルが入力より多ければ L/R を繰り返す
                        let v = inS[f * inCh + (c % inCh)] * g
                        out[f * outCh + c] = v
                        let a = abs(v); if a > peak { peak = a }
                    }
                }
                if n < nOut { memset(out + n * outCh, 0, (nOut - n) * outCh * MemoryLayout<Float>.size) }
            }
            // ピークは「読み出しまでの最大値」。競合しても表示用なので relaxed で十分
            if peak > shared.peak.load(ordering: .relaxed) { shared.peak.store(peak, ordering: .relaxed) }
        }
    }
}
