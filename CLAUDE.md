# Sidecast

macOSで「特定アプリの音声だけをHDMI出力に流し、それ以外は通常の出力のまま」にするメニューバー常駐アプリ。
個人の週末プロジェクト。自分のMacでだけ動けばよい（署名・公証・配布・他環境互換は一切考慮しない）。

- リポジトリ: https://github.com/takashick3/Sidecast
- 作業ディレクトリ: `/Users/fujiwara/ClaudeProjects/Sidecast/`
- bundle ID: `org.takashick.Sidecast`
- 対応OS: macOS 27以降のみ（古いOSへの配慮は不要）
- ライセンス: MIT（LICENSEファイルを初回コミットに含める）

## セッション開始時の手順

1. この `CLAUDE.md` の「現状」節を読んで前後関係を把握する
2. `git status` / `git log --oneline -10` で作業状態を確認する
3. 直前のPoC結果があれば `docs/poc-log.md` を読む
4. その上で「今日やること」を1〜3行で提示し、確認を取ってから着手する

## 作業ルール

- **変更を加える行動**（ファイル作成・変更、git操作、ビルド設定変更、権限設定の変更）は**事前に確認を取る**。調査（ファイル読み、ドキュメント参照、`system_profiler` 等の読み取りコマンド、ビルドのみ）は確認不要
- 失敗して別手段に切り替えたら「①何が問題か ②どう回避したか ③恒久対策の要否」をセットで報告する
- 動作確認をしたら、確認方法（コマンド・手順）を添える
- 会話は日本語。技術的内容は詳しく、コマンドやコードは具体的に、説明は簡潔に
- PoCの各ステップの結果は `docs/poc-log.md` に日付付きで追記する（成功/失敗/観測した挙動/判断）
- セッション終了時、またはフェーズが進んだら、この `CLAUDE.md` の「現状」節を更新する

### Git

- 個人プロジェクトなので**個人アカウント takashick3** でコミットする
- 初回に必ずこのリポジトリのローカル設定に `git config user.name` / `git config user.email` を入れ、`git config --get user.email` で業務アカウント（echfujiwara / ec-h.co.jp）が使われていないことを確認してから最初のコミットを行う
- push先は `git@github.com:takashick3/Sidecast.git`（または https）。remote追加時にURLを確認する
- コミット・pushの前には必ず確認を取る
- コミットメッセージは英語の簡潔な命令形（例: `Add process dump PoC`）

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
└── Sidecast/               # Xcodeプロジェクト（PoC完了後に作成）
```

## 進め方: PoCで未検証事項を先に潰す（UIは後）

`PoC/` にUI無しのCLI（Swift Package executable）を作り、以下を順に確認する。**各ステップで結果を報告し、次に進む前に確認を取る。**

1. **プロセスダンプ**: 音を出しているプロセスを PID / bundle ID / 責任プロセス(bundle ID) 付きでダンプする。
   特に確認: Core Audioが `kAudioProcessPropertyBundleID` としてXPCサービス（`com.apple.WebKit.GPU`）を返すのか、ホストに解決済みで返すのか。後者なら責任プロセス解決は省ける
2. **ミュート検証**: Music.appをタップし `mutedWhenTapped` で**本当に元出力が無音になるか**。ダメなら方式ごと再検討
3. **集約再生**: タップ＋HDMIの集約デバイスで再生。タップ側（44.1kHz等）とHDMI（48kHz等）のサンプルレート差を集約デバイスが透過的に吸収するか。
   ダメなら第2案（タップ専用集約＋リングバッファ＋`AVAudioEngine` でHDMI再生）へ降格
4. **保護コンテンツ**: Apple Musicのストリーミング/ロスレスがタップで取れるか（無音にならないか）
5. **gainと再構築**: ソフトgainの適用、HDMI抜き差し・Music再起動時の再構築

ここまで通ったら `Sidecast/` にXcodeプロジェクトを作ってUIを載せる。

## 現状

- 2026-09-18: 設計フェーズ完了（この文書が設計）。GitHubリポジトリ作成済み（空）、作業ディレクトリ作成済み。コード未着手。
- 2026-09-18: git 初期化・初回コミット済み（remote は HTTPS。SSH 鍵は業務アカウントに紐づくため使わない）。**PoC 1（プロセスダンプ）成功** — Core Audio は helper/XPC の bundle ID をそのまま返すため責任プロセス解決が必要と確定。詳細は `docs/poc-log.md`
- 2026-09-18: **PoC 2（mutedWhenTapped）成功** — 元出力が完全に無音化し、タップ側に 48 kHz float で音声が流れることを確認。方式確定。注意: IOProc ブロックは `nonisolated` 関数で生成しないと MainActor 推論で SIGTRAP
- 2026-09-18: **PoC 3（集約再生）成功** — タップ＋HDMI の集約デバイスで再生・ソフト gain・レート差（48k→44.1k）の透過リサンプルまで確認。第 1 案で確定、リングバッファ不要
- **次にやること**: PoC 4（Apple Music ロスレス/保護コンテンツがタップで取れるか）→ PoC 5（HDMI 抜き差し・Music 再起動時の再構築）。eqMac は停止済み、既定出力は本体スピーカー、HDMI は 48 kHz に戻し済み
