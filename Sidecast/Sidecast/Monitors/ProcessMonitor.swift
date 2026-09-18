// 音声プロセス一覧（責任プロセス解決済み）の監視。
// kAudioHardwarePropertyProcessObjectList の変更で一覧を更新し onChange を呼ぶ。

import Foundation
import CoreAudio
import Observation

@MainActor
@Observable
final class ProcessMonitor {
    private(set) var processes: [AudioProcessInfo] = []
    var onChange: (@MainActor () -> Void)?

    init() {
        refresh()
        var addr = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            MainActor.assumeIsolated {
                self.refresh()
                self.onChange?()
            }
        }
    }

    func refresh() {
        let mine = ProcessInfo.processInfo.processIdentifier
        processes = snapshotAudioProcesses().filter { $0.pid != mine && $0.hostPID != mine }
    }

    /// UI の「追加」候補: 現在出力中で、まだ登録されていないもの（ホスト名でソート）
    func candidates(excluding targets: [TargetApp]) -> [AudioProcessInfo] {
        let registered = Set(targets.map { $0.id })
        var seen = Set<String>()
        return processes
            .filter { $0.isRunningOutput && !registered.contains(TargetApp.id(host: $0.hostBundleID, audio: $0.bundleID)) }
            .filter { seen.insert(TargetApp.id(host: $0.hostBundleID, audio: $0.bundleID)).inserted }
            .sorted { ($0.hostName, $0.bundleID) < ($1.hostName, $1.bundleID) }
    }

    /// 登録済みペアに一致するプロセスオブジェクト（責任プロセスの bundle ID も一致するもののみ）
    func objectIDs(for targets: [TargetApp]) -> [AudioObjectID] {
        let wanted = Set(targets.map { $0.id })
        return processes
            .filter { wanted.contains(TargetApp.id(host: $0.hostBundleID, audio: $0.bundleID)) }
            .map { $0.objectID }
            .sorted()
    }
}
