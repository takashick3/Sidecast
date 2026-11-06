# Sidecast 設計書（CLAUDE.md から分離・2026-11-05）

設計時（2026-09-18）の決定事項。実装は完了しており、変更するときはここを更新する。

## 要件

- 対象アプリ（当初はMusic.app。後でChrome系ブラウザ、Safariも指定可能に）の音声をHDMIデバイスへ再生する
- 対象アプリの音は元の出力先では鳴らない
- HDMI音量をUIから調整できる
- UIはメニューバーのみ: ON/OFFトグル、対象アプリの追加/削除、HDMI音量スライダー

## 方式（決定事項）

HALプラグイン/仮想オーディオドライバは使わない。**Core Audio Process Taps** で実装する。

- `CATapDescription` + `AudioHardwareCreateProcessTap` で対象プロセスのタップを作る
- `muteBehavior = .mutedWhenTapped` で対象アプリの元出力を無音化する
- タップとHDMI出力デバイスを**同一の集約デバイス**に入れる
  （`kAudioAggregateDeviceTapListKey` + `kAudioAggregateDeviceSubDeviceListKey`、`kAudioAggregateDeviceIsPrivateKey = true`）
- 1本のIOProc（`AudioDeviceCreateIOProcIDWithBlock`）内で、タップ入力バッファ → gain乗算 → HDMI出力バッファへコピー。リングバッファ・クロック補正は自前で持たない
- HDMI音量はハード音量（`kAudioDevicePropertyVolumeScalar`）が設定不可な前提で、IOProc内の**ソフトウェアgain**で実現
- 参考実装: insidegui/AudioCap（Process Tapの作法）。コードをコピーする場合は元のLICENSEに従い著作権表示を残す

## アプリ指定の設計（決定事項）

- 対象は「実行中で音を出しているプロセス」（`kAudioHardwarePropertyProcessObjectList` のうち `kAudioProcessPropertyIsRunningOutput` が真）から選ばせる。/Applicationsからのファイル選択方式は採らない
- ブラウザ等は音を出すのが子プロセス（Chrome: `com.google.Chrome.helper`、Safari: `com.apple.WebKit.GPU`）。`com.apple.WebKit.GPU` は同名プロセスが他アプリ配下にも存在するため、bundle ID単体では判定しない
- **責任プロセス**で絞る: `responsibility_get_pid_responsible_for_pid(pid)`（libquarantine、非公開API、`dlsym` で取得）でホストアプリのPIDを解決する
- 永続化する登録単位は `(hostBundleID, audioProcessBundleID)` のペア。タップ対象を組む際、責任PIDのbundle IDがhostと一致するプロセスのみ拾う
- UIの選択リストは責任プロセス単位でグルーピング（例: 「Safari ▸ WebKit GPU」）

## 動的追従（決定事項）

- `kAudioHardwarePropertyProcessObjectList` の変更リスナーで対象プロセスの出入りを検知したら、タップと集約デバイスを**破棄して作り直す**（`CATapDescription` は実質イミュータブル）。作り直し中の瞬断は許容
- `kAudioHardwarePropertyDevices` の変更リスナーでHDMIの抜き差し/スリープを検知。消えたら全部tear down（元出力で鳴る状態に自然フォールバック）、戻ったら再構築。HDMIデバイスはUIDで保存
- システム出力がHDMI自身に設定されている場合はタップしない（無駄なループ防止）

## 構成

- Swift / SwiftUI、`MenuBarExtra` の常駐アプリ（Dockアイコンなし、`LSUIElement`）。Xcodeプロジェクト1本、外部依存なし
- レイヤ:
  - `AudioEngine` — タップ・集約デバイス・IOProc。**リアルタイム安全**（IOProc内でロック・アロケーション・Swiftの参照型操作・ログ出力・ObjCメッセージ送信を一切しない）
  - `ProcessMonitor` — 音声プロセス一覧の監視と責任プロセス解決
  - `DeviceMonitor` — HDMIデバイスの監視
  - `Settings` — UserDefaults（有効フラグ、対象ペア配列、HDMI UID、gain）
  - `MenuBarView` — SwiftUI
- gainはUI→IOProcへ `Atomic<Float>`（Synchronization framework）で渡す
- Info.plistに `NSAudioCaptureUsageDescription` を記載。初回にTCC（システムオーディオ録音）許可を通す
- ログイン項目登録（SMAppService）は最後で可

### ディレクトリ構成（予定）

```
Sidecast/
├── CLAUDE.md
├── LICENSE                 # MIT
├── README.md
├── docs/
│   └── poc-log.md          # PoC結果ログ
├── PoC/                    # Swift Package (executable)、UI無しのCLI群
│   └── Package.swift
└── Sidecast/               # アプリ本体
    ├── project.yml         # xcodegen 定義（`cd Sidecast && xcodegen generate` で .xcodeproj を生成。xcodeproj と build/ は git 管理外）
    └── Sidecast/           # ソース（Audio/ Monitors/ UI/ Settings.swift SidecastController.swift）
```
