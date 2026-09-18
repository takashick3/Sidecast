// 各 PoC で共有する Core Audio ヘルパ。リアルタイムスレッドからは呼ばない。

import Foundation
import CoreAudio
import AppKit
import Darwin

public func propertyAddress(_ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

public func readScalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var addr = propertyAddress(selector, scope: scope)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var size = UInt32(MemoryLayout<T>.size)
    let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr) == noErr else { return nil }
    return ptr.pointee
}

public func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = propertyAddress(selector)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
    guard status == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

public func readObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = propertyAddress(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = list.withUnsafeMutableBufferPointer { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
    guard status == noErr else { return [] }
    return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

/// 4 文字コードの OSStatus を人間が読める形にする
public func describe(_ status: OSStatus) -> String {
    let u = UInt32(bitPattern: status)
    let bytes = [UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
    }
    return "\(status)"
}

// MARK: - Processes

/// Core Audio のプロセスオブジェクトのうち bundle ID が一致するものを返す
public func audioProcessObjects(bundleID: String) -> [AudioObjectID] {
    readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).filter {
        readString($0, kAudioProcessPropertyBundleID) == bundleID
    }
}

public typealias ResponsibleForPIDFn = @convention(c) (pid_t) -> pid_t

/// libquarantine の非公開 API `responsibility_get_pid_responsible_for_pid`
public let responsibleForPID: ResponsibleForPIDFn? = {
    var sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") // RTLD_DEFAULT
    if sym == nil, let h = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_NOW) {
        sym = dlsym(h, "responsibility_get_pid_responsible_for_pid")
    }
    guard let s = sym else { return nil }
    return unsafeBitCast(s, to: ResponsibleForPIDFn.self)
}()

public func executablePath(of pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

public func bundleID(of pid: pid_t) -> String? {
    if let app = NSRunningApplication(processIdentifier: pid), let b = app.bundleIdentifier { return b }
    guard let path = executablePath(of: pid) else { return nil }
    var url = URL(fileURLWithPath: path)
    while url.path != "/" {
        if ["app", "xpc", "appex"].contains(url.pathExtension) { return Bundle(url: url)?.bundleIdentifier }
        url.deleteLastPathComponent()
    }
    return nil
}

public func processName(of pid: pid_t) -> String {
    if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
    if let p = executablePath(of: pid) { return URL(fileURLWithPath: p).lastPathComponent }
    return "?"
}

// MARK: - Devices

public func defaultOutputDevice() -> AudioObjectID? {
    readScalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
}

public func deviceUID(_ device: AudioObjectID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
public func deviceName(_ device: AudioObjectID) -> String? { readString(device, kAudioObjectPropertyName) }

public func describeFormat(_ f: AudioStreamBasicDescription) -> String {
    let isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let nonInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    return "\(f.mSampleRate) Hz, \(f.mChannelsPerFrame) ch, \(f.mBitsPerChannel)-bit \(isFloat ? "float" : "int")\(nonInterleaved ? ", non-interleaved" : "")"
}

// MARK: - Device enumeration

public struct OutputDeviceInfo {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: String
    public let nominalSampleRate: Double
    public let availableSampleRates: [Double]
    public let outputChannels: Int
    public let volumeSettable: Bool
    public let volumeScalar: Float?
    public let isDefaultOutput: Bool
}

public func allDevices() -> [AudioObjectID] {
    readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
}

public func transportTypeName(_ t: UInt32) -> String {
    switch t {
    case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
    default:
        let b = [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)]
        return String(decoding: b, as: UTF8.self)
    }
}

public func outputChannelCount(_ device: AudioObjectID) -> Int {
    var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

public func availableSampleRates(_ device: AudioObjectID) -> [Double] {
    var addr = propertyAddress(kAudioDevicePropertyAvailableNominalSampleRates)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard ranges.withUnsafeMutableBufferPointer({ AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0.baseAddress!) }) == noErr else { return [] }
    return ranges.map { $0.mMinimum }
}

public func outputDeviceInfo(_ id: AudioObjectID) -> OutputDeviceInfo? {
    let ch = outputChannelCount(id)
    guard ch > 0 else { return nil }
    var volAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var settable: DarwinBoolean = false
    var hasVol = false
    if AudioObjectHasProperty(id, &volAddr) {
        hasVol = true
        AudioObjectIsPropertySettable(id, &volAddr, &settable)
    } else {
        // main element に無い場合はチャンネル 1 を見る
        volAddr.mElement = 1
        if AudioObjectHasProperty(id, &volAddr) { hasVol = true; AudioObjectIsPropertySettable(id, &volAddr, &settable) }
    }
    var vol: Float? = nil
    if hasVol {
        var size = UInt32(MemoryLayout<Float>.size); var v: Float = 0
        if AudioObjectGetPropertyData(id, &volAddr, 0, nil, &size, &v) == noErr { vol = v }
    }
    return OutputDeviceInfo(
        id: id,
        uid: deviceUID(id) ?? "",
        name: deviceName(id) ?? "",
        transport: transportTypeName(readScalar(id, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0),
        nominalSampleRate: readScalar(id, kAudioDevicePropertyNominalSampleRate, as: Double.self) ?? 0,
        availableSampleRates: availableSampleRates(id),
        outputChannels: ch,
        volumeSettable: hasVol && settable.boolValue,
        volumeScalar: vol,
        isDefaultOutput: defaultOutputDevice() == id
    )
}

public func outputDevices() -> [OutputDeviceInfo] { allDevices().compactMap(outputDeviceInfo) }
