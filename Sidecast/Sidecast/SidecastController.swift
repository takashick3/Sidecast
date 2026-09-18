// 設定・監視・エンジンを束ね、「今タップすべき状態か」を判定して AudioEngine を構築/破棄する。
// PoC 5 の rebuild を移植。ホットプラグ後の 2 秒安定待ちとストール監視を含む。

import Foundation
import CoreAudio
import Observation
import os

@MainActor
@Observable
final class SidecastController {
    let settings = Settings()
    let processes = ProcessMonitor()
    let devices = DeviceMonitor()
    @ObservationIgnored let engine = AudioEngine()

    /// メニューに出す状態
    private(set) var statusText = "停止中"
    private(set) var isActive = false
    private(set) var lastError: String?

    @ObservationIgnored private let log = Logger(subsystem: "org.takashick.Sidecast", category: "Controller")
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReasons: [String] = []
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var needsReconcile = false
    @ObservationIgnored private var hdmiWasPresent = false
    @ObservationIgnored private var settleUntil: Date = .distantPast
    @ObservationIgnored private var lastCallbacks: UInt64 = 0
    @ObservationIgnored private var stalledTicks = 0
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    init() {
        engine.setGain(settings.gain)
        hdmiWasPresent = devices.device(uid: settings.hdmiUID) != nil
        processes.onChange = { [weak self] in self?.scheduleReconcile("processes") }
        devices.onChange = { [weak self] kind in
            guard let self else { return }
            let present = devices.device(uid: settings.hdmiUID) != nil
            if kind == "devices", present, !hdmiWasPresent {
                // HDMI 再出現直後に構築すると IOProc が回らない集約デバイスができる（PoC 5）。2 秒待つ
                settleUntil = Date().addingTimeInterval(2.0)
            }
            hdmiWasPresent = present
            scheduleReconcile(kind)
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.stallCheck()
            }
        }
        scheduleReconcile("startup")
    }

    // MARK: UI からの操作

    func setEnabled(_ on: Bool) { settings.isEnabled = on; scheduleReconcile("enabled") }
    func setHDMI(uid: String?) {
        settings.hdmiUID = uid
        hdmiWasPresent = devices.device(uid: uid) != nil
        scheduleReconcile("hdmi")
    }
    func setGain(_ g: Float) { settings.gain = g; engine.setGain(g) }
    func addTarget(_ p: AudioProcessInfo) {
        let t = TargetApp(p)
        guard !settings.targets.contains(where: { $0.id == t.id }) else { return }
        settings.targets.append(t)
        scheduleReconcile("targets")
    }
    func removeTarget(_ t: TargetApp) { settings.targets.removeAll { $0.id == t.id }; scheduleReconcile("targets") }

    // MARK: 判定と再構築

    /// 変更通知は短時間に連続するので 300 ms でまとめる
    private func scheduleReconcile(_ reason: String) {
        pendingReasons.append(reason)
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let r = pendingReasons.joined(separator: "+"); pendingReasons = []
            await reconcile(reason: r)
        }
    }

    private func reconcile(reason: String) async {
        if reconciling { needsReconcile = true; return }
        reconciling = true
        defer { reconciling = false }

        let hdmi = devices.device(uid: settings.hdmiUID)
        let procs = processes.objectIDs(for: settings.targets)
        let hdmiIsDefault = hdmi != nil && hdmi?.uid == devices.defaultOutputUID

        var why: String? = nil
        if !settings.isEnabled { why = "停止中" }
        else if settings.hdmiUID == nil { why = "出力先が未選択" }
        else if hdmi == nil { why = "出力先が接続されていません" }
        else if hdmiIsDefault { why = "出力先がシステムの既定出力のため待機" }
        else if settings.targets.isEmpty { why = "対象アプリが未登録" }
        else if procs.isEmpty { why = "対象アプリが起動していません" }

        log.info("reconcile(\(reason, privacy: .public)): hdmi=\(hdmi?.name ?? "nil", privacy: .public) procs=\(procs) running=\(self.engine.isRunning)")

        if let why {
            if engine.isRunning { await engine.tearDown() }
            isActive = false; statusText = why
            finishReconcile(); return
        }
        let hdmiUID = hdmi!.uid
        if engine.isRunning && engine.tappedProcesses == procs && engine.tappedHDMIUID == hdmiUID {
            finishReconcile(); return
        }
        let wait = settleUntil.timeIntervalSinceNow
        if wait > 0 {
            statusText = "出力先の準備を待っています…"
            reconciling = false
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                await self?.reconcile(reason: "settled")
            }
            return
        }
        do {
            try await engine.build(processes: procs, hdmiUID: hdmiUID)
            lastCallbacks = engine.callbackCount; stalledTicks = 0
            isActive = true; lastError = nil
            statusText = "\(hdmi!.name) へ出力中（\(procs.count) プロセス）"
        } catch {
            isActive = false
            lastError = "\(error)"
            statusText = "エラー: \(error)"
            log.error("build failed: \(error, privacy: .public)")
        }
        finishReconcile()
    }

    private func finishReconcile() {
        if needsReconcile { needsReconcile = false; scheduleReconcile("followup") }
    }

    // MARK: ストール監視

    /// 対象プロセスが出力中なのに IOProc のコールバックが 2 秒進まなければ集約デバイスが空回りしている（PoC 5）。作り直す
    private func stallCheck() {
        guard engine.isRunning, !reconciling else { stalledTicks = 0; lastCallbacks = engine.callbackCount; return }
        let cb = engine.callbackCount
        if cb != lastCallbacks {
            lastCallbacks = cb; stalledTicks = 0
            if retryCount > 0 { log.info("watchdog: IO recovered"); retryCount = 0 }
            return
        }
        let tapped = Set(engine.tappedProcesses)
        let outputting = processes.processes.contains { tapped.contains($0.objectID) && $0.isRunningOutput }
        guard outputting else { stalledTicks = 0; return }
        stalledTicks += 1
        guard stalledTicks >= 2 else { return }
        stalledTicks = 0
        retryCount += 1
        guard retryCount <= 5 else {
            log.error("watchdog: giving up after 5 retries")
            Task { await engine.tearDown(); isActive = false; statusText = "出力が停止しました（再接続してください）" }
            return
        }
        let delay = min(8.0, 0.5 * pow(2.0, Double(retryCount - 1)))
        log.warning("watchdog: no IO callbacks for 2s, rebuilding in \(delay)s (retry \(self.retryCount))")
        Task { [weak self] in
            guard let self else { return }
            await engine.tearDown()
            try? await Task.sleep(for: .seconds(delay))
            await reconcile(reason: "watchdog")
        }
    }
}
