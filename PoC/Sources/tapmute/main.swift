// PoC 2: ミュート検証
// 対象プロセス (既定: com.apple.Music) を Process Tap でタップし、mutedWhenTapped で
// 元出力 (本体スピーカー等) が本当に無音になるかを人間の耳で確認する。
// タップ側に音声が流れていることは IOProc 内で計測したピークレベルで確認する。
//
// 使い方: tapmute [--bundle <id>] [--no-mute] [--no-agg] [--seconds N]
//   --no-mute : muteBehavior を .unmuted にして比較する
//   --no-agg  : 集約デバイスを作らずタップだけ作る (タップ単体で mute が効くかの確認)
//   --seconds : 計測秒数 (既定 20)。Ctrl-C でも終了する

import Foundation
import CoreAudio
import PoCCommon

// MARK: - IOProc (リアルタイムスレッドから呼ばれる。MainActor 推論を避けるため nonisolated 関数で生成する)

nonisolated func makeIOBlock(peak: UnsafeMutablePointer<Float>, frames: UnsafeMutablePointer<UInt64>,
                             callbacks: UnsafeMutablePointer<UInt64>) -> AudioDeviceIOBlock {
    return { _, inInputData, _, outOutputData, _ in
        // ロック・アロケーション・ログ禁止
        callbacks.pointee &+= 1
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        var localPeak = peak.pointee
        for buf in inBuffers {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n { let v = abs(samples[i]); if v > localPeak { localPeak = v } }
            if buf.mNumberChannels > 0 { frames.pointee &+= UInt64(n / Int(buf.mNumberChannels)) }
        }
        peak.pointee = localPeak
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        for buf in outBuffers { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
    }
}

// MARK: - 引数

setlinebuf(stdout)

var targetBundle = "com.apple.Music"
var mute = true
var useAggregate = true
var seconds = 20
var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--bundle": targetBundle = args.removeFirst()
    case "--no-mute": mute = false
    case "--no-agg": useAggregate = false
    case "--seconds": seconds = Int(args.removeFirst()) ?? 20
    default: print("unknown arg \(a)"); exit(2)
    }
}

// MARK: - リアルタイム側と共有する計測値 (PoC なので単純なポインタ。本番では Atomic を使う)

let peakPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1); peakPtr.initialize(to: 0)
let framesPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); framesPtr.initialize(to: 0)
let callbacksPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); callbacksPtr.initialize(to: 0)

// MARK: - 対象プロセス

let procs = audioProcessObjects(bundleID: targetBundle)
guard !procs.isEmpty else {
    print("対象プロセス \(targetBundle) が Core Audio のプロセス一覧に見つかりません。アプリを起動して音を出してください。")
    exit(1)
}
for p in procs {
    let pid = readScalar(p, kAudioProcessPropertyPID, as: pid_t.self) ?? -1
    let out = (readScalar(p, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0
    print("target: objID \(p) pid \(pid) \(targetBundle) isRunningOutput=\(out)")
}

let outDev = defaultOutputDevice() ?? 0
print("default output device: \(deviceName(outDev) ?? "?") uid=\(deviceUID(outDev) ?? "?")")

// MARK: - タップ作成

let desc = CATapDescription(stereoMixdownOfProcesses: procs)
desc.uuid = UUID()
desc.name = "Sidecast PoC tap"
desc.isPrivate = true
desc.muteBehavior = mute ? .mutedWhenTapped : .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
var st = AudioHardwareCreateProcessTap(desc, &tapID)
guard st == noErr else { print("AudioHardwareCreateProcessTap failed: \(describe(st))"); exit(1) }
print("tap created: id \(tapID) muteBehavior=\(mute ? "mutedWhenTapped" : "unmuted")")
if let fmt = readScalar(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) {
    print("tap format: \(describeFormat(fmt))")
}

// MARK: - 集約デバイス + IOProc

var aggID = AudioObjectID(kAudioObjectUnknown)
var ioProcID: AudioDeviceIOProcID? = nil

if useAggregate {
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Sidecast PoC aggregate",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        // PoC 2 では出力先を持たせない。クロック源としてサブデバイスが必要なら既定出力を入れる (AudioCap 方式)
        kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: desc.uuid.uuidString,
        ]],
    ]
    st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
    guard st == noErr else { print("AudioHardwareCreateAggregateDevice failed: \(describe(st))"); AudioHardwareDestroyProcessTap(tapID); exit(1) }
    print("aggregate created: id \(aggID)")

    st = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil, makeIOBlock(peak: peakPtr, frames: framesPtr, callbacks: callbacksPtr))
    guard st == noErr, let procID = ioProcID else { print("AudioDeviceCreateIOProcIDWithBlock failed: \(describe(st))"); exit(1) }
    st = AudioDeviceStart(aggID, procID)
    guard st == noErr else { print("AudioDeviceStart failed: \(describe(st))"); exit(1) }
    print("IOProc started")
    if let fmt = readScalar(aggID, kAudioDevicePropertyStreamFormat, as: AudioStreamBasicDescription.self, scope: kAudioObjectPropertyScopeInput) {
        print("aggregate input format: \(describeFormat(fmt))")
    }
} else {
    print("(--no-agg) 集約デバイスは作らずタップのみで待機")
}

// MARK: - 計測ループと後始末

@MainActor func tearDown() {
    if let procID = ioProcID {
        AudioDeviceStop(aggID, procID)
        AudioDeviceDestroyIOProcID(aggID, procID)
    }
    if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
    AudioHardwareDestroyProcessTap(tapID)
    print("torn down (tap/aggregate destroyed). 元出力で音が戻るか確認してください。")
}

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigint.setEventHandler { tearDown(); exit(0) }
sigint.resume()

print("")
print(">>> 今、\(mute ? "本体スピーカーから対象アプリの音が消えている" : "本体スピーカーで対象アプリの音が鳴り続けている")はずです。\(seconds) 秒間計測します (Ctrl-C で終了)")
var elapsed = 0
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    elapsed += 1
    let peak = peakPtr.pointee
    peakPtr.pointee = 0
    let db = peak > 0 ? 20 * log10(peak) : -Float.infinity
    print(String(format: "t=%2ds callbacks=%llu frames=%llu peak=%.4f (%.1f dBFS)", elapsed, callbacksPtr.pointee, framesPtr.pointee, peak, db))
    if elapsed >= seconds { tearDown(); exit(0) }
}
timer.resume()
dispatchMain()
