// PoC 3: 集約再生
// 対象プロセスのタップと HDMI 出力デバイスを 1 つの私的な集約デバイスに入れ、
// 1 本の IOProc でタップ入力 → gain 乗算 → HDMI 出力へコピーする。
// 確認したいこと: タップ側と HDMI 側のサンプルレート差を集約デバイスが透過的に吸収するか。
//
// 使い方: aggplay --list-devices
//         aggplay --device <UID または名前の一部> [--bundle com.apple.Music] [--gain 0.5] [--seconds 30] [--no-mute]
//         aggplay --device <...> --set-rate 44100   (デバイスの公称サンプルレートを変更して終了)

import Foundation
import CoreAudio
import PoCCommon

// MARK: - IOProc (nonisolated で生成。ロック・アロケーション・ログ禁止)

nonisolated func makeIOBlock(gain: UnsafeMutablePointer<Float>, inPeak: UnsafeMutablePointer<Float>,
                             callbacks: UnsafeMutablePointer<UInt64>, inFrames: UnsafeMutablePointer<UInt64>,
                             outFrames: UnsafeMutablePointer<UInt64>) -> AudioDeviceIOBlock {
    return { _, inInputData, _, outOutputData, _ in
        callbacks.pointee &+= 1
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        let g = gain.pointee
        var peak = inPeak.pointee

        // 入力はタップ 1 ストリーム (インターリーブ 2ch float) を想定
        guard let inBuf = inBuffers.first, let inData = inBuf.mData, inBuf.mNumberChannels > 0 else {
            for ob in outBuffers { if let d = ob.mData { memset(d, 0, Int(ob.mDataByteSize)) } }
            return
        }
        let inCh = Int(inBuf.mNumberChannels)
        let inSamples = inData.assumingMemoryBound(to: Float.self)
        let nInFrames = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size / inCh
        inFrames.pointee &+= UInt64(nInFrames)

        for ob in outBuffers {
            guard let outData = ob.mData, ob.mNumberChannels > 0 else { continue }
            let outCh = Int(ob.mNumberChannels)
            let out = outData.assumingMemoryBound(to: Float.self)
            let nOutFrames = Int(ob.mDataByteSize) / MemoryLayout<Float>.size / outCh
            let n = min(nInFrames, nOutFrames)
            for f in 0..<n {
                for c in 0..<outCh {
                    // 出力チャンネルが入力より多ければ L/R を繰り返す。少なければ先頭チャンネルのみ
                    let v = inSamples[f * inCh + (c % inCh)] * g
                    out[f * outCh + c] = v
                    let a = abs(v); if a > peak { peak = a }
                }
            }
            if n < nOutFrames { memset(out + n * outCh, 0, (nOutFrames - n) * outCh * MemoryLayout<Float>.size) }
            outFrames.pointee &+= UInt64(nOutFrames)
        }
        inPeak.pointee = peak
    }
}

setlinebuf(stdout)

// MARK: - 引数

var listOnly = false
var deviceQuery: String? = nil
var targetBundle = "com.apple.Music"
var gainValue: Float = 0.5
var seconds = 30
var mute = true
var setRate: Double? = nil
var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--list-devices": listOnly = true
    case "--device": deviceQuery = args.removeFirst()
    case "--bundle": targetBundle = args.removeFirst()
    case "--gain": gainValue = Float(args.removeFirst()) ?? 0.5
    case "--seconds": seconds = Int(args.removeFirst()) ?? 30
    case "--no-mute": mute = false
    case "--set-rate": setRate = Double(args.removeFirst())
    default: print("unknown arg \(a)"); exit(2)
    }
}

let devices = outputDevices()
if listOnly || deviceQuery == nil {
    print("output devices:")
    for d in devices {
        print(String(format: "  id=%-4d %@ %-28@ %-12@ %6.0f Hz  rates=%@  ch=%d  volumeSettable=%@ vol=%@  uid=%@",
                     d.id, d.isDefaultOutput ? "*" : " ", d.name, d.transport, d.nominalSampleRate,
                     d.availableSampleRates.map { String(Int($0)) }.joined(separator: "/"), d.outputChannels,
                     d.volumeSettable ? "Y" : "N", d.volumeScalar.map { String(format: "%.2f", $0) } ?? "-", d.uid))
    }
    // 残留タップの確認 (システムオブジェクトの kAudioHardwarePropertyTapList)
    let taps = readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTapList)
    print("process taps in system: \(taps.count) \(taps)")
    for t in taps {
        print("  tap \(t): uid=\(readString(t, kAudioTapPropertyUID) ?? "?") format=\(readScalar(t, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self).map(describeFormat) ?? "?")")
    }
    let all = allDevices()
    print("all devices: \(all.map { "\($0):\(deviceName($0) ?? "?")[\(transportTypeName(readScalar($0, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0))]" })")
    if deviceQuery == nil { print("\n--device <UID か名前の一部> を指定してください") }
    exit(0)
}

// MARK: - デバイス・プロセス解決

guard let hdmi = devices.first(where: { $0.uid.localizedCaseInsensitiveContains(deviceQuery!) || $0.name.localizedCaseInsensitiveContains(deviceQuery!) }) else {
    print("デバイス '\(deviceQuery!)' が見つかりません。--list-devices で確認してください"); exit(1)
}
if let rate = setRate {
    var addr = propertyAddress(kAudioDevicePropertyNominalSampleRate)
    var r = rate
    let st = AudioObjectSetPropertyData(hdmi.id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &r)
    guard st == noErr else { print("set nominal sample rate failed: \(describe(st))"); exit(1) }
    // 反映は非同期なので少し待って読み戻す
    Thread.sleep(forTimeInterval: 0.5)
    print("\(hdmi.name): nominal sample rate -> \(Int(readScalar(hdmi.id, kAudioDevicePropertyNominalSampleRate, as: Double.self) ?? 0)) Hz")
    exit(0)
}
guard !hdmi.isDefaultOutput else {
    print("指定デバイスが既定出力そのものです。設計どおりタップしません（既定出力を別デバイスに切り替えてください）"); exit(1)
}
print("output: \(hdmi.name) [\(hdmi.transport)] \(Int(hdmi.nominalSampleRate)) Hz \(hdmi.outputChannels)ch uid=\(hdmi.uid)")

let procs = audioProcessObjects(bundleID: targetBundle)
guard !procs.isEmpty else { print("対象プロセス \(targetBundle) が見つかりません"); exit(1) }
print("target: \(targetBundle) objIDs=\(procs)")
let defOut = defaultOutputDevice() ?? 0
print("default output (stays for other apps): \(deviceName(defOut) ?? "?") \(Int(readScalar(defOut, kAudioDevicePropertyNominalSampleRate, as: Double.self) ?? 0)) Hz")

// MARK: - タップ

let desc = CATapDescription(stereoMixdownOfProcesses: procs)
desc.uuid = UUID()
desc.name = "Sidecast PoC tap"
desc.isPrivate = true
desc.muteBehavior = mute ? .mutedWhenTapped : .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
var st = AudioHardwareCreateProcessTap(desc, &tapID)
guard st == noErr else { print("AudioHardwareCreateProcessTap failed: \(describe(st))"); exit(1) }
if let fmt = readScalar(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) {
    print("tap format (before aggregate): \(describeFormat(fmt))")
}

// MARK: - 集約デバイス

let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Sidecast PoC aggregate",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceMainSubDeviceKey: hdmi.uid,     // クロックマスターは HDMI
    kAudioAggregateDeviceSubDeviceListKey: [[
        kAudioSubDeviceUIDKey: hdmi.uid,
        kAudioSubDeviceDriftCompensationKey: false,
    ]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapUIDKey: desc.uuid.uuidString,
        kAudioSubTapDriftCompensationKey: true,
    ]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard st == noErr else { print("AudioHardwareCreateAggregateDevice failed: \(describe(st))"); AudioHardwareDestroyProcessTap(tapID); exit(1) }
print("aggregate: id \(aggID), nominal \(Int(readScalar(aggID, kAudioDevicePropertyNominalSampleRate, as: Double.self) ?? 0)) Hz")
if let fmt = readScalar(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) {
    print("tap format (after aggregate):  \(describeFormat(fmt))")
}
if let fmt = readScalar(aggID, kAudioDevicePropertyStreamFormat, as: AudioStreamBasicDescription.self, scope: kAudioObjectPropertyScopeInput) {
    print("aggregate input  stream: \(describeFormat(fmt))")
}
if let fmt = readScalar(aggID, kAudioDevicePropertyStreamFormat, as: AudioStreamBasicDescription.self, scope: kAudioObjectPropertyScopeOutput) {
    print("aggregate output stream: \(describeFormat(fmt))")
}
print("aggregate output channels: \(outputChannelCount(aggID))")

// MARK: - IOProc

let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1); gainPtr.initialize(to: gainValue)
let peakPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1); peakPtr.initialize(to: 0)
let cbPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); cbPtr.initialize(to: 0)
let inFramesPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); inFramesPtr.initialize(to: 0)
let outFramesPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); outFramesPtr.initialize(to: 0)

var ioProcID: AudioDeviceIOProcID? = nil
st = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil,
                                        makeIOBlock(gain: gainPtr, inPeak: peakPtr, callbacks: cbPtr, inFrames: inFramesPtr, outFrames: outFramesPtr))
guard st == noErr, let procID = ioProcID else { print("AudioDeviceCreateIOProcIDWithBlock failed: \(describe(st))"); exit(1) }
st = AudioDeviceStart(aggID, procID)
guard st == noErr else { print("AudioDeviceStart failed: \(describe(st))"); exit(1) }
print("IOProc started, gain=\(gainValue)")

@MainActor func tearDown() {
    AudioDeviceStop(aggID, procID)
    AudioDeviceDestroyIOProcID(aggID, procID)
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    print("torn down. 元出力で音が戻るか確認してください。")
}
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigint.setEventHandler { tearDown(); exit(0) }
sigint.resume()

print("\n>>> 対象アプリの音が \(hdmi.name) から鳴り、本体スピーカーでは鳴らないはずです。\(seconds) 秒間計測します。")
print(">>> 途中で gain を変えます: 10 秒後に 0.1、20 秒後に 1.0 (音量の変化を確認してください)")
var elapsed = 0
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    elapsed += 1
    if elapsed == 10 { gainPtr.pointee = 0.1; print("--- gain -> 0.1") }
    if elapsed == 20 { gainPtr.pointee = 1.0; print("--- gain -> 1.0") }
    let peak = peakPtr.pointee; peakPtr.pointee = 0
    print(String(format: "t=%2ds callbacks=%llu inFrames=%llu outFrames=%llu outPeak=%.4f", elapsed, cbPtr.pointee, inFramesPtr.pointee, outFramesPtr.pointee, peak))
    if elapsed >= seconds { tearDown(); exit(0) }
}
timer.resume()
dispatchMain()
