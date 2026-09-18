// PoC 5: 再構築
// kAudioHardwarePropertyProcessObjectList / kAudioHardwarePropertyDevices / DefaultOutputDevice の
// 変更リスナーで対象プロセスの出入り・HDMI の抜き差し・既定出力の変更を検知し、
// タップ + 集約デバイスを破棄して作り直す。Ctrl-C まで常駐する。
//
// 使い方: rebuild --device <HDMI の UID か名前の一部> [--bundle com.apple.Music] [--gain 0.5]
// 試すこと: 実行中に (a) Music を終了→再起動→再生 (b) HDMI ケーブルを抜く→挿す (c) 既定出力を HDMI に切替→戻す

import Foundation
import CoreAudio
import PoCCommon

// MARK: - IOProc (nonisolated で生成。ロック・アロケーション・ログ禁止)

nonisolated func makeIOBlock(gain: UnsafeMutablePointer<Float>, peak: UnsafeMutablePointer<Float>,
                             callbacks: UnsafeMutablePointer<UInt64>) -> AudioDeviceIOBlock {
    return { _, inInputData, _, outOutputData, _ in
        callbacks.pointee &+= 1
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        let g = gain.pointee
        var pk = peak.pointee
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
            for f in 0..<n { for c in 0..<outCh { let v = inS[f * inCh + (c % inCh)] * g; out[f * outCh + c] = v; let a = abs(v); if a > pk { pk = a } } }
            if n < nOut { memset(out + n * outCh, 0, (nOut - n) * outCh * MemoryLayout<Float>.size) }
        }
        peak.pointee = pk
    }
}

setlinebuf(stdout)

func ts() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
}
func log(_ s: String) { print("[\(ts())] \(s)") }

// MARK: - 引数

var deviceQuery: String? = nil
var targetBundle = "com.apple.Music"
var gainValue: Float = 0.5
var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--device": deviceQuery = args.removeFirst()
    case "--bundle": targetBundle = args.removeFirst()
    case "--gain": gainValue = Float(args.removeFirst()) ?? 0.5
    default: print("unknown arg \(a)"); exit(2)
    }
}
guard let q = deviceQuery,
      let hdmiInfo = outputDevices().first(where: { $0.uid.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) }) else {
    print("--device <UID か名前の一部> を指定してください（aggplay --list-devices で確認）"); exit(1)
}
let hdmiUID = hdmiInfo.uid   // 保存するのは UID。以後はこれで探す
log("HDMI UID = \(hdmiUID) (\(hdmiInfo.name)), target = \(targetBundle)")

// MARK: - エンジン (MainActor 上で操作)

@MainActor
final class Engine {
    let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let peakPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let cbPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID? = nil
    private(set) var tappedProcs: [AudioObjectID] = []
    var isRunning: Bool { aggID != kAudioObjectUnknown }
    var rebuildCount = 0
    var generation = 0          // build ごとに増える。ウォッチドッグの対象判定に使う
    var retryCount = 0          // 連続ウォッチドッグ再構築の回数

    init(gain: Float) { gainPtr.initialize(to: gain); peakPtr.initialize(to: 0); cbPtr.initialize(to: 0) }

    func build(procs: [AudioObjectID], hdmi: AudioObjectID) -> Bool {
        // ホットプラグ直後の診断: デバイスが生きているか・ストリームが揃っているか
        let alive = readScalar(hdmi, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) ?? 99
        let runningSomewhere = readScalar(hdmi, kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 99
        let streams = readObjectList(hdmi, kAudioDevicePropertyStreams).count
        let rate = readScalar(hdmi, kAudioDevicePropertyNominalSampleRate, as: Double.self) ?? 0
        log("  hdmi \(hdmi): alive=\(alive) runningSomewhere=\(runningSomewhere) streams=\(streams) rate=\(Int(rate))")
        let desc = CATapDescription(stereoMixdownOfProcesses: procs)
        desc.uuid = UUID(); desc.name = "Sidecast PoC tap"; desc.isPrivate = true; desc.muteBehavior = .mutedWhenTapped
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { log("  tap create failed: \(describe(st))"); tapID = kAudioObjectUnknown; return false }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sidecast PoC aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: hdmiUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: hdmiUID, kAudioSubDeviceDriftCompensationKey: false]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard st == noErr else { log("  aggregate create failed: \(describe(st))"); tearDown(); return false }
        st = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil, makeIOBlock(gain: gainPtr, peak: peakPtr, callbacks: cbPtr))
        guard st == noErr, let p = ioProcID else { log("  ioproc create failed: \(describe(st))"); tearDown(); return false }
        st = AudioDeviceStart(aggID, p)
        guard st == noErr else { log("  start failed: \(describe(st))"); tearDown(); return false }
        tappedProcs = procs
        rebuildCount += 1
        generation += 1
        addDiagListeners(agg: aggID, hdmi: hdmi)
        let fmt = readScalar(aggID, kAudioDevicePropertyStreamFormat, as: AudioStreamBasicDescription.self, scope: kAudioObjectPropertyScopeOutput)
        log("  BUILT #\(rebuildCount): tap \(tapID) procs \(procs) agg \(aggID) out \(fmt.map(describeFormat) ?? "?")")
        return true
    }

    func tearDown() {
        if let p = ioProcID, aggID != kAudioObjectUnknown { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
        ioProcID = nil
        var aggSt: OSStatus = noErr, tapSt: OSStatus = noErr
        if aggID != kAudioObjectUnknown { aggSt = AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { tapSt = AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
        if !tappedProcs.isEmpty { log("  TORN DOWN (destroy agg=\(describe(aggSt)) tap=\(describe(tapSt)))") }
        tappedProcs = []
    }
}

let engine = Engine(gain: gainValue)

// MARK: - 状態判定と再構築

@MainActor func reconcile(reason: String) {
    let hdmi = allDevices().first { deviceUID($0) == hdmiUID }
    let defOut = defaultOutputDevice()
    let procs = audioProcessObjects(bundleID: targetBundle).sorted()
    let hdmiIsDefault = hdmi != nil && hdmi == defOut

    var want = true
    var why = ""
    if hdmi == nil { want = false; why = "HDMI not present" }
    else if hdmiIsDefault { want = false; why = "HDMI is the default output (no tap)" }
    else if procs.isEmpty { want = false; why = "target process not running" }

    log("reconcile(\(reason)): hdmi=\(hdmi.map(String.init) ?? "nil") default=\(deviceName(defOut ?? 0) ?? "?") procs=\(procs) running=\(engine.isRunning) tapped=\(engine.tappedProcs)")
    if !want {
        if engine.isRunning { log("  -> tear down: \(why)") ; engine.tearDown() } else { log("  -> idle: \(why)") }
        return
    }
    if engine.isRunning && engine.tappedProcs == procs { log("  -> no change"); return }
    if reason.contains("devices") && !reason.contains("settled") {
        log("  -> HDMI (re)appeared, waiting 2s for hotplug to settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { reconcile(reason: "devices-settled") }
        return
    }
    if engine.isRunning { log("  -> process set changed, rebuilding"); engine.tearDown() } else { log("  -> building") }
    _ = engine.build(procs: procs, hdmi: hdmi!)
}

// ストール監視 (1 秒ごと): 対象プロセスが出力中なのに IOProc のコールバックが 2 秒進まなければ
// 集約デバイスが空回りしていると判断して破棄・再構築する (バックオフ付き、連続 5 回で諦める)。
// 対象が一時停止中はコールバックが止まるのが正常なので、isRunningOutput を条件に入れる。
var lastCallbacks: UInt64 = 0
var stalledTicks = 0
@MainActor func targetIsOutputting() -> Bool {
    engine.tappedProcs.contains { (readScalar($0, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0 }
}
@MainActor func stallCheck() {
    guard engine.isRunning else { stalledTicks = 0; lastCallbacks = engine.cbPtr.pointee; return }
    let cb = engine.cbPtr.pointee
    if cb != lastCallbacks { lastCallbacks = cb; stalledTicks = 0; if engine.retryCount > 0 { log("  watchdog: IO recovered"); engine.retryCount = 0 }; return }
    guard targetIsOutputting() else { stalledTicks = 0; return }
    stalledTicks += 1
    guard stalledTicks >= 2 else { return }
    stalledTicks = 0
    engine.retryCount += 1
    guard engine.retryCount <= 5 else { log("  WATCHDOG: giving up after 5 retries"); engine.tearDown(); return }
    let delay = min(8.0, 0.5 * pow(2.0, Double(engine.retryCount - 1)))
    log("  WATCHDOG: target outputting but no IO callbacks for 2s (gen \(engine.generation)), rebuilding in \(delay)s (retry \(engine.retryCount))")
    engine.tearDown()
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { reconcile(reason: "watchdog") }
}
let stallTimer = DispatchSource.makeTimerSource(queue: .main)
stallTimer.schedule(deadline: .now() + 1, repeating: 1)
stallTimer.setEventHandler { stallCheck() }
stallTimer.resume()

// 診断用: 集約デバイスの IsRunning と HDMI のレート変更・オーバーロードを記録
@MainActor func addDiagListeners(agg: AudioObjectID, hdmi: AudioObjectID) {
    for (obj, sel, name) in [(agg, kAudioDevicePropertyDeviceIsRunning, "agg.isRunning"),
                             (hdmi, kAudioDevicePropertyNominalSampleRate, "hdmi.rate"),
                             (hdmi, kAudioDeviceProcessorOverload, "hdmi.overload"),
                             (hdmi, kAudioDevicePropertyDeviceIsAlive, "hdmi.alive"),
                             (hdmi, kAudioDevicePropertyStreamFormat, "hdmi.streamFormat")] {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: sel == kAudioDevicePropertyStreamFormat ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(obj, &addr, .main) { _, _ in
            let v: String
            switch sel {
            case kAudioDevicePropertyDeviceIsRunning: v = "\(readScalar(obj, sel, as: UInt32.self) ?? 99)"
            case kAudioDevicePropertyNominalSampleRate: v = "\(Int(readScalar(obj, sel, as: Double.self) ?? 0))"
            case kAudioDevicePropertyDeviceIsAlive: v = "\(readScalar(obj, sel, as: UInt32.self) ?? 99)"
            default: v = "-"
            }
            log("  diag \(name) changed -> \(v)")
        }
    }
}

// 変更通知は短時間に連続するので 300ms でまとめる
var pending: DispatchWorkItem? = nil
var pendingReasons: [String] = []
@MainActor func scheduleReconcile(_ reason: String) {
    pendingReasons.append(reason)
    pending?.cancel()
    let w = DispatchWorkItem { let r = pendingReasons.joined(separator: "+"); pendingReasons = []; reconcile(reason: r) }
    pending = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
}

// MARK: - リスナー登録

let sys = AudioObjectID(kAudioObjectSystemObject)
for (sel, name) in [(kAudioHardwarePropertyProcessObjectList, "processes"), (kAudioHardwarePropertyDevices, "devices"), (kAudioHardwarePropertyDefaultOutputDevice, "defaultOutput")] {
    var addr = propertyAddress(sel)
    let st = AudioObjectAddPropertyListenerBlock(sys, &addr, .main) { _, _ in scheduleReconcile(name) }
    log("listener \(name): \(st == noErr ? "ok" : describe(st))")
}

// 対象プロセスの isRunningOutput の変化も見たい場合は各プロセスオブジェクトにリスナーを付けるが、PoC では一覧の増減のみ

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigint.setEventHandler { engine.tearDown(); log("exit"); exit(0) }
sigint.resume()

reconcile(reason: "startup")
print("\n>>> 常駐中 (Ctrl-C で終了)。試すこと: Music 終了→再起動→再生 / HDMI 抜く→挿す / 既定出力を HDMI に→戻す")
let status = DispatchSource.makeTimerSource(queue: .main)
status.schedule(deadline: .now() + 5, repeating: 5)
status.setEventHandler {
    let pk = engine.peakPtr.pointee; engine.peakPtr.pointee = 0
    let d = defaultOutputDevice() ?? 0
    var volAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var vol: Float = -1; var sz = UInt32(MemoryLayout<Float>.size)
    _ = AudioObjectGetPropertyData(d, &volAddr, 0, nil, &sz, &vol)
    let muted = readScalar(d, kAudioDevicePropertyMute, as: UInt32.self, scope: kAudioObjectPropertyScopeOutput) ?? 99
    log(String(format: "status: running=%@ callbacks=%llu peak=%.3f rebuilds=%d | default=%@ vol=%.2f mute=%u", engine.isRunning ? "Y" : "N", engine.cbPtr.pointee, pk, engine.rebuildCount, deviceName(d) ?? "?", vol, muted))
}
status.resume()
dispatchMain()
