// UserDefaults に保存する設定。

import Foundation
import Observation

/// 登録単位は (ホストアプリの bundle ID, 実際に音を出すプロセスの bundle ID) のペア
struct TargetApp: Codable, Hashable, Identifiable, Sendable {
    var hostBundleID: String
    var audioBundleID: String
    var displayName: String
    var id: String { Self.id(host: hostBundleID, audio: audioBundleID) }
    static func id(host: String, audio: String) -> String { host + "|" + audio }

    init(_ p: AudioProcessInfo) {
        hostBundleID = p.hostBundleID
        audioBundleID = p.bundleID
        displayName = p.displayName
    }
}

@MainActor
@Observable
final class Settings {
    private enum Key {
        static let enabled = "isEnabled"
        static let targets = "targets"
        static let hdmiUID = "hdmiUID"
        static let gain = "gain"
    }
    private let defaults = UserDefaults.standard

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    var targets: [TargetApp] { didSet { defaults.set(try? JSONEncoder().encode(targets), forKey: Key.targets) } }
    var hdmiUID: String? { didSet { defaults.set(hdmiUID, forKey: Key.hdmiUID) } }
    var gain: Float { didSet { defaults.set(gain, forKey: Key.gain) } }

    init() {
        isEnabled = defaults.bool(forKey: Key.enabled)
        targets = defaults.data(forKey: Key.targets).flatMap { try? JSONDecoder().decode([TargetApp].self, from: $0) } ?? []
        hdmiUID = defaults.string(forKey: Key.hdmiUID)
        gain = defaults.object(forKey: Key.gain) == nil ? 0.5 : defaults.float(forKey: Key.gain)
    }
}
