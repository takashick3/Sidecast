// Core Audio のプロパティ読み書き・プロセス/デバイス情報のヘルパ。
// すべて非リアルタイムスレッド用（IOProc から呼ばない）。PoC の PoCCommon から移植。

import Foundation
import CoreAudio
import AppKit
import Darwin

// MARK: - Property access

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readScalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var addr = propertyAddress(selector, scope: scope)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var size = UInt32(MemoryLayout<T>.size)
    let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr) == noErr else { return nil }
    return ptr.pointee
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = propertyAddress(selector)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
    guard status == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

func readObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = list.withUnsafeMutableBufferPointer { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
    guard status == noErr else { return [] }
    return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

/// OSStatus を 4 文字コード付きで表示用に整形する
func describe(_ status: OSStatus) -> String {
    let u = UInt32(bitPattern: status)
    let bytes = [UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
    }
    return "\(status)"
}

// MARK: - Processes

/// Core Audio が見ている音声プロセス 1 つ分。責任プロセス（ホストアプリ）解決済み
struct AudioProcessInfo: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
    let hostPID: pid_t
    let hostBundleID: String
    let hostName: String
    var id: AudioObjectID { objectID }
    /// 自分自身がホストならホスト名のみ、helper/XPC なら「ホスト ▸ helper」
    var displayName: String {
        bundleID == hostBundleID ? hostName : "\(hostName) ▸ \(bundleID.split(separator: ".").last.map(String.init) ?? bundleID)"
    }
}

private typealias ResponsibleForPIDFn = @convention(c) (pid_t) -> pid_t

/// libquarantine の非公開 API `responsibility_get_pid_responsible_for_pid`。dlsym(RTLD_DEFAULT) で解決できる（PoC 1 で確認）
private let responsibleForPID: ResponsibleForPIDFn? = {
    var sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    if sym == nil, let h = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_NOW) {
        sym = dlsym(h, "responsibility_get_pid_responsible_for_pid")
    }
    guard let s = sym else { return nil }
    return unsafeBitCast(s, to: ResponsibleForPIDFn.self)
}()

private func executablePath(of pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func bundleID(of pid: pid_t) -> String? {
    if let app = NSRunningApplication(processIdentifier: pid), let b = app.bundleIdentifier { return b }
    guard let path = executablePath(of: pid) else { return nil }
    var url = URL(fileURLWithPath: path)
    while url.path != "/" {
        if ["app", "xpc", "appex"].contains(url.pathExtension) { return Bundle(url: url)?.bundleIdentifier }
        url.deleteLastPathComponent()
    }
    return nil
}

private func processName(of pid: pid_t) -> String {
    if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
    if let p = executablePath(of: pid) { return URL(fileURLWithPath: p).lastPathComponent }
    return "?"
}

/// 現在の音声プロセス一覧を責任プロセス付きで取得する
func snapshotAudioProcesses() -> [AudioProcessInfo] {
    readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { obj in
        guard let pid = readScalar(obj, kAudioProcessPropertyPID, as: pid_t.self), pid > 0 else { return nil }
        let bundle = readString(obj, kAudioProcessPropertyBundleID) ?? ""
        guard !bundle.isEmpty else { return nil }
        let out = (readScalar(obj, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0
        var hostPID = responsibleForPID?(pid) ?? -1
        if hostPID <= 0 { hostPID = pid }
        let hostBundle = bundleID(of: hostPID) ?? bundle
        return AudioProcessInfo(objectID: obj, pid: pid, bundleID: bundle, isRunningOutput: out,
                                hostPID: hostPID, hostBundleID: hostBundle, hostName: processName(of: hostPID))
    }
}

// MARK: - Devices

struct OutputDeviceInfo: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: String
    let nominalSampleRate: Double
    let outputChannels: Int
}

func defaultOutputDevice() -> AudioObjectID? {
    readScalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
}
func deviceUID(_ device: AudioObjectID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
func deviceName(_ device: AudioObjectID) -> String? { readString(device, kAudioObjectPropertyName) }
func allDevices() -> [AudioObjectID] { readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) }

func transportTypeName(_ t: UInt32) -> String {
    switch t {
    case kAudioDeviceTransportTypeBuiltIn: return "内蔵"
    case kAudioDeviceTransportTypeAggregate: return "集約"
    case kAudioDeviceTransportTypeVirtual: return "仮想"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    default: return "その他"
    }
}

func outputChannelCount(_ device: AudioObjectID) -> Int {
    var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}

/// 出力チャンネルを持つデバイス（自分の私的な集約デバイスは kAudioAggregateDeviceIsPrivateKey により列挙されない）
func snapshotOutputDevices() -> [OutputDeviceInfo] {
    allDevices().compactMap { id in
        let ch = outputChannelCount(id)
        guard ch > 0 else { return nil }
        return OutputDeviceInfo(
            id: id, uid: deviceUID(id) ?? "", name: deviceName(id) ?? "?",
            transport: transportTypeName(readScalar(id, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0),
            nominalSampleRate: readScalar(id, kAudioDevicePropertyNominalSampleRate, as: Double.self) ?? 0,
            outputChannels: ch)
    }
}
