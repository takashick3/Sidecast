// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidecastPoC",
    platforms: [.macOS(.v15)],
    targets: [
        // 各 PoC で共有する Core Audio プロパティ読み書き・プロセス解決ヘルパ
        .target(name: "PoCCommon", path: "Sources/PoCCommon"),
        // PoC 1: 音声プロセスを PID / bundle ID / 責任プロセス付きでダンプ
        .executableTarget(name: "procdump", dependencies: ["PoCCommon"], path: "Sources/procdump"),
        // PoC 2: 対象プロセスをタップし mutedWhenTapped で元出力が無音になるか検証
        .executableTarget(name: "tapmute", dependencies: ["PoCCommon"], path: "Sources/tapmute"),
        // PoC 3: タップ + HDMI サブデバイスの集約デバイスで再生 (ソフト gain 付き)
        .executableTarget(name: "aggplay", dependencies: ["PoCCommon"], path: "Sources/aggplay"),
        // PoC 5: プロセス/デバイス変更リスナーでタップ+集約デバイスを破棄・再構築
        .executableTarget(name: "rebuild", dependencies: ["PoCCommon"], path: "Sources/rebuild"),
    ]
)
