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

## 2026-09-19

### PoC 4: 保護コンテンツ（Apple Music ロスレス） — 成功

- 実行: Music の設定でロスレスを有効にし、Lossless バッジ付きの曲を再生した状態で `PoC/.build/debug/aggplay --device GDQ271JA --seconds 20 --gain 1.0`
- タップは正常に音声を受信（出力ピーク約 0.20、gain 0.1 で 0.02 に比例）。**ロスレスでもタップが無音になったりエラーになったりしない**
- タップ経由のフォーマットは通常音質時と同じ 48 kHz / 2ch / 32-bit float（Core Audio がミックスダウン後の PCM を渡す）。ハイレゾロスレス（96k/192k）はタップ側でデバイスレートにダウンサンプルされることになるが、HDMI が 48 kHz 上限なので実用上の損失はない
- 判断: 保護コンテンツは障害にならない。PoC 5（再構築）へ

### PoC 5: gain と再構築 — 成功（対策 2 点を追加して）

- 実装: `PoC/Sources/rebuild/main.swift`。実行: `cd PoC && swift build && .build/debug/rebuild --device GDQ271JA --gain 1.0`（常駐、Ctrl-C で終了）
- ソフト gain は PoC 3 で確認済み（IOProc 内の乗算、即時反映）
- リスナー: システムオブジェクトの `ProcessObjectList` / `Devices` / `DefaultOutputDevice` の 3 つ。通知は 300 ms でデバウンスし、`reconcile()` で「HDMI が存在 && HDMI が既定出力でない && 対象プロセスが存在」を判定して build / tear down / no change に分岐。集約デバイス作成による自己通知は「no change」で吸収され、再構築ループは起きない
- **Music 終了→再起動**: プロセス消失で tear down、新プロセス出現で再構築、再生開始でモニタへ。✓
- **既定出力を HDMI に切替→戻す**: HDMI が既定出力の間はタップせず Music は通常経路で HDMI へ。戻すと再構築してモニタへ。✓
- **HDMI 抜く**: デバイス消失で tear down、Music は本体スピーカーへ自然フォールバック。✓
- **HDMI 挿し直す（問題あり→対策）**: 再出現直後（300 ms 後）に構築すると、`AudioDeviceStart` は成功を返すのに **IOProc が回らない／数回で止まる**集約デバイスができることがある（3 回中 2 回再現。HDMI の alive・ストリーム数・レートは正常値で事前判別不可）。タップが非アクティブなので mute も掛からず本体で鳴り続ける。対策として
  1. **ホットプラグ後 2 秒の安定待ち**（`devices` 通知で HDMI が再出現したら 2 秒後に構築）
  2. **常時ストール監視**（1 秒ごと。対象プロセスが `isRunningOutput` なのにコールバックが 2 秒進まなければ破棄・再構築。0.5 s→8 s のバックオフ、連続 5 回で断念。対象が一時停止中はコールバックが止まるのが正常なので条件に含める）
  を入れた後は 2 回とも挿し直し後すぐモニタへ復帰。ストール監視は発火せず（1. だけで足りている可能性が高いが、保険として両方残す）
- **観測: HDMI が消えた状態での tear down（`AudioDeviceStop` / `AudioHardwareDestroyAggregateDevice`）は約 14 秒ブロックする**。メインスレッドで呼ぶと UI が固まるので、本番の `AudioEngine` では tear down を専用のシリアルキューで行うこと
- 観測: 対象プロセスが出力していない間（Music 一時停止・起動直後）は集約デバイスの IOProc コールバックが来ない（タップ入力が無いと IO サイクルが走らない）。ストール判定の条件に `isRunningOutput` が必要な理由
- 別件: 1 回目のテストで「内蔵スピーカーが無音」になったのはシステム出力音量 0 ＋ミュートが原因で、タップとは無関係（原因操作は不明）。念のため status ログに既定出力の音量・ミュートを出すようにした
- 判断: **PoC フェーズ完了。全 5 ステップ通過。** 次は `Sidecast/` に Xcode プロジェクトを作って UI を載せる

### PoC から本番実装へ持ち越す注意点（まとめ）

1. IOProc ブロックは `nonisolated` 関数で生成する（MainActor 推論で SIGTRAP）
2. 実フォーマットは集約デバイスの `kAudioDevicePropertyStreamFormat`（input scope）から読む。`kAudioTapPropertyFormat` は当てにならない
3. HDMI 再出現後は 2 秒待って構築し、ストール監視（isRunningOutput 条件付き）を常時回す
4. tear down はメインスレッド以外で行う（デバイス消失時に約 14 秒ブロック）
5. 集約デバイス作成は自分自身に `Devices` 変更通知を起こすので reconcile は冪等に書く
6. 責任プロセス解決（`responsibility_get_pid_responsible_for_pid`）は `dlsym(RTLD_DEFAULT)` で取れる
