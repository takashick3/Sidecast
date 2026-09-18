// PoC 1: プロセスダンプ
// Core Audio のプロセスオブジェクト一覧を PID / bundle ID / 責任プロセス付きでダンプする。
// 確認したいこと: kAudioProcessPropertyBundleID が XPC サービス (com.apple.WebKit.GPU 等) を
// そのまま返すのか、ホストアプリに解決済みで返すのか。

import Foundation
import CoreAudio

import PoCCommon

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
