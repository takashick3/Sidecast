// 出力デバイス一覧と既定出力の監視。HDMI の抜き差し・スリープ・既定出力の切替を検知する。

import Foundation
import CoreAudio
import Observation

@MainActor
@Observable
final class DeviceMonitor {
    private(set) var outputDevices: [OutputDeviceInfo] = []
    private(set) var defaultOutputUID: String?
    /// 引数: 変更の種類（"devices" / "defaultOutput"）
    var onChange: (@MainActor (String) -> Void)?

    init() {
        refresh()
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for (sel, name) in [(kAudioHardwarePropertyDevices, "devices"), (kAudioHardwarePropertyDefaultOutputDevice, "defaultOutput")] {
            var addr = propertyAddress(sel)
            AudioObjectAddPropertyListenerBlock(sys, &addr, .main) { _, _ in
                MainActor.assumeIsolated {
                    self.refresh()
                    self.onChange?(name)
                }
            }
        }
    }

    func refresh() {
        outputDevices = snapshotOutputDevices()
        defaultOutputUID = defaultOutputDevice().flatMap(deviceUID)
    }

    func device(uid: String?) -> OutputDeviceInfo? {
        guard let uid else { return nil }
        return outputDevices.first { $0.uid == uid }
    }
}
