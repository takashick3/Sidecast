# PoC ログ

各ステップの結果を日付付きで追記する（成功/失敗/観測した挙動/判断）。
ステップ定義は `CLAUDE.md` の「進め方」節を参照。

## 2026-09-18

- リポジトリ初期化・初回コミット（f4eab1d）。

### PoC 1: プロセスダンプ — 成功

- 実装: `PoC/Sources/procdump/main.swift`。実行: `cd PoC && swift build && .build/debug/procdump`（`--output-only` で出力中のみ）
- `kAudioHardwarePropertyProcessObjectList` は 48 オブジェクト。`kAudioProcessPropertyIsRunningOutput` が真だったのは Music.app と eqMac の 2 つ
- **`kAudioProcessPropertyBundleID` は XPC/helper の bundle ID をそのまま返す**（ホストに解決されない）。
  例: `com.apple.WebKit.GPU`(pid 3053) の責任プロセスは Safari(3036)、`com.google.Chrome.helper` → `com.google.Chrome`、`notion.id.helper` → `notion.id`
  → **責任プロセス解決は必要**（設計どおり）
- `responsibility_get_pid_responsible_for_pid` は `dlsym(RTLD_DEFAULT)` で解決でき、非 root で動作した
- `com.apple.WebKit.GPU` は Safari 以外に Outlook / Google Drive / eqMac / TeamViewer / QuickLook 配下にも存在 → bundle ID 単体で判定しない方針が正しいことを確認
- 責任 PID が -1 になるのは bundle ID 空のデーモン系（pid 687/688、systemsoundserverd 等）。対象外なので影響なし
- **環境上の注意**: `com.bitgapp.eqmac`（eqMac）が常時出力中。eqMac は仮想デバイスに全システム音声を通す方式のため、PoC 2（mute）・PoC 3（集約再生）の観測に干渉し得る。**PoC 2 以降は eqMac を終了した状態で検証する**
- 判断: 設計変更なし。PoC 2（`mutedWhenTapped` の検証）へ進む

### PoC 2: ミュート検証 — 成功

- 実装: `PoC/Sources/tapmute/main.swift`。実行: `cd PoC && swift build && .build/debug/tapmute --seconds 20`（`--no-mute` / `--no-agg` で比較可）
- 事前条件: eqMac 停止、既定出力を MacBook Pro スピーカーに戻した状態。Music.app（Apple Music ストリーミングと思われる）を再生中
- `CATapDescription(stereoMixdownOfProcesses:)` + `muteBehavior = .mutedWhenTapped` でタップ作成 → **本体スピーカーから Music の音が完全に消えた**（耳で確認）。tear down 後は元出力で鳴る状態に戻った
- タップ側には音声が流れている: ピーク約 -14 dBFS、20 秒で 1874 コールバック / 959,488 フレーム（48 kHz × 20 秒に一致、欠落なし）
- タップフォーマットは 48 kHz / 2ch / 32-bit float（既定出力デバイスのレートに追従していると思われる）
- **集約デバイスはサブデバイス無し（タップのみ）でも起動し IOProc が回る**。クロックはタップ側で供給される
- TCC（システムオーディオ録音）の許可ダイアログは出なかった。CLI からの実行では要求されないか、既に許可済み。Xcode アプリ化時に再確認する
- ハマりどころ: トップレベルコードで書いた IOProc クロージャが Swift 6 で `@MainActor` に推論され、リアルタイムスレッドから呼ばれた瞬間に `dispatch_assert_queue` で SIGTRAP（exit 133）。**IOProc ブロックは `nonisolated` 関数で生成する**こと。本番 `AudioEngine` でも同じ注意が必要
- 副次的に PoC 4 の一部を先取り: Apple Music ストリーミングは通常音質ではタップで取れる（無音にならない）。ロスレス/保護コンテンツの挙動は PoC 4 で別途確認
- 判断: 方式（Process Tap + mutedWhenTapped）を確定。PoC 3（タップ＋HDMI の集約デバイスで再生）へ進む

### PoC 3: 集約再生 — 成功

- 実装: `PoC/Sources/aggplay/main.swift`。実行: `cd PoC && swift build && .build/debug/aggplay --list-devices` → `.build/debug/aggplay --device GDQ271JA --seconds 30`
- HDMI モニタ GDQ271JA: transport=HDMI、2ch、対応レート 32k/44.1k/48k、**ハード音量は設定不可**（`kAudioDevicePropertyVolumeScalar` なし）→ ソフト gain 方式が必要と確定
- 集約デバイス構成: `kAudioAggregateDeviceMainSubDeviceKey` = HDMI（クロックマスター）、サブデバイス = HDMI（drift 補正 off）、タップ（drift 補正 on）、private
- **同レート（48k/48k）**: モニタから Music が鳴り、本体スピーカーは無音、gain 0.5→0.1→1.0 の変化が聞き取れ、tear down 後に本体へ戻る（すべて耳で確認）。30 秒で入出力フレーム数一致（約 1.44M）、途切れ・ノイズなし
- **レート差（タップ 48k / HDMI 44.1k）**: `kAudioTapPropertyFormat` は 48 kHz のまま報告されるが、**集約デバイスの入力ストリームは IOProc に 44.1 kHz で届く**（1 秒あたり約 44,032 フレーム、入出力フレーム数が毎コールバック一致）。つまり集約デバイスがタップ側を透過的にリサンプルする。自前のリングバッファ・レート変換は不要（設計の第 1 案で確定、第 2 案への降格なし）
- ソフト gain は IOProc 内の乗算で即時反映（出力ピークが gain に比例）
- 注意: `kAudioTapPropertyFormat` の値は実際に IOProc に渡るフォーマットとは一致しないことがある。実フォーマットは集約デバイスの `kAudioDevicePropertyStreamFormat`（input scope）を見る
- 判断: 方式確定。残りは PoC 4（ロスレス/保護コンテンツ）と PoC 5（HDMI 抜き差し・Music 再起動時の再構築）
