// PoC 1: プロセスダンプ
// Core Audio のプロセスオブジェクト一覧を PID / bundle ID / 責任プロセス付きでダンプする。
// 確認したいこと: kAudioProcessPropertyBundleID が XPC サービス (com.apple.WebKit.GPU 等) を
// そのまま返すのか、ホストアプリに解決済みで返すのか。

import Foundation
import CoreAudio
import AppKit
import Darwin

// MARK: - Core Audio property helpers

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func readScalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type) -> T? {
    var addr = address(selector)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var size = UInt32(MemoryLayout<T>.size)
    let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { ptr.deallocate() }
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
    guard status == noErr else { return nil }
    return ptr.pointee
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) { p in
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, p)
    }
    guard status == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

func readObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var list = [AudioObjectID](repeating: 0, count: count)
    let status = list.withUnsafeMutableBufferPointer { buf in
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buf.baseAddress!)
    }
    guard status == noErr else { return [] }
    return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

// MARK: - Responsible process (libquarantine, private API)

typealias ResponsibleForPIDFn = @convention(c) (pid_t) -> pid_t

let responsibleForPID: ResponsibleForPIDFn? = {
    // libquarantine は libSystem 経由でロード済みのはずなので RTLD_DEFAULT で探し、無ければ明示ロード
    var sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") // RTLD_DEFAULT
    if sym == nil, let h = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_NOW) {
        sym = dlsym(h, "responsibility_get_pid_responsible_for_pid")
    }
    guard let s = sym else { return nil }
    return unsafeBitCast(s, to: ResponsibleForPIDFn.self)
}()

// MARK: - Process info helpers

func executablePath(of pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(cString: buf)
}

func bundleID(of pid: pid_t) -> String? {
    if let app = NSRunningApplication(processIdentifier: pid), let b = app.bundleIdentifier {
        return b
    }
    // NSRunningApplication で取れない (GUI アプリでない) 場合は実行パスから .app / .xpc バンドルを辿る
    guard let path = executablePath(of: pid) else { return nil }
    var url = URL(fileURLWithPath: path)
    while url.path != "/" {
        let ext = url.pathExtension
        if ext == "app" || ext == "xpc" || ext == "appex" {
            return Bundle(url: url)?.bundleIdentifier
        }
        url.deleteLastPathComponent()
    }
    return nil
}

func processName(of pid: pid_t) -> String {
    if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
    if let p = executablePath(of: pid) { return URL(fileURLWithPath: p).lastPathComponent }
    return "?"
}

// MARK: - Dump

struct Row {
    let object: AudioObjectID
    let pid: pid_t
    let caBundleID: String
    let isRunning: Bool
    let isRunningOutput: Bool
    let isRunningInput: Bool
    let responsiblePID: pid_t
    let responsibleBundleID: String
    let responsibleName: String
}

let onlyOutput = CommandLine.arguments.contains("--output-only")

let processObjects = readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
print("kAudioHardwarePropertyProcessObjectList: \(processObjects.count) objects")
print("responsibility_get_pid_responsible_for_pid: \(responsibleForPID == nil ? "NOT FOUND" : "resolved")")
print("")

var rows: [Row] = []
for obj in processObjects {
    let pid = readScalar(obj, kAudioProcessPropertyPID, as: pid_t.self) ?? -1
    let caBundle = readString(obj, kAudioProcessPropertyBundleID) ?? ""
    let running = (readScalar(obj, kAudioProcessPropertyIsRunning, as: UInt32.self) ?? 0) != 0
    let runningOut = (readScalar(obj, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0
    let runningIn = (readScalar(obj, kAudioProcessPropertyIsRunningInput, as: UInt32.self) ?? 0) != 0
    let rpid = responsibleForPID?(pid) ?? -1
    let rBundle = rpid > 0 ? (bundleID(of: rpid) ?? "") : ""
    let rName = rpid > 0 ? processName(of: rpid) : "?"
    rows.append(Row(object: obj, pid: pid, caBundleID: caBundle,
                    isRunning: running, isRunningOutput: runningOut, isRunningInput: runningIn,
                    responsiblePID: rpid, responsibleBundleID: rBundle, responsibleName: rName))
}

let shown = onlyOutput ? rows.filter { $0.isRunningOutput } : rows
print(String(format: "%-6@ %-7@ %-3@ %-3@ %-3@ %-40@ %-7@ %-30@ %@",
             "objID", "pid", "run", "out", "in", "CoreAudio bundleID", "rPID", "responsible bundleID", "responsible name"))
for r in shown.sorted(by: { ($0.isRunningOutput ? 0 : 1, $0.responsibleBundleID, $0.pid) < ($1.isRunningOutput ? 0 : 1, $1.responsibleBundleID, $1.pid) }) {
    let flag = { (b: Bool) in b ? "Y" : "-" }
    print(String(format: "%-6d %-7d %-3@ %-3@ %-3@ %-40@ %-7d %-30@ %@",
                 r.object, r.pid, flag(r.isRunning), flag(r.isRunningOutput), flag(r.isRunningInput),
                 r.caBundleID, r.responsiblePID, r.responsibleBundleID, r.responsibleName))
}

// 判定サマリ: CoreAudio の bundleID と責任プロセスの bundleID が食い違う (= XPC/helper がそのまま返っている) ケース
let mismatched = rows.filter { $0.isRunningOutput && !$0.caBundleID.isEmpty && !$0.responsibleBundleID.isEmpty && $0.caBundleID != $0.responsibleBundleID }
print("")
print("outputting processes: \(rows.filter { $0.isRunningOutput }.count)")
print("outputting with CoreAudio bundleID != responsible bundleID: \(mismatched.count)")
for m in mismatched {
    print("  \(m.caBundleID) (pid \(m.pid)) -> host \(m.responsibleBundleID) (pid \(m.responsiblePID))")
}
