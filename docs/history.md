# Sidecast 進め方と作業ログ（CLAUDE.md から分離・2026-11-05）

PoC の計画（設計時）と、日付付きの作業ログ。PoC 各ステップの観測結果は `poc-log.md`。

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
- 2026-09-19: **PoC 4（ロスレス）成功**、**PoC 5（再構築）成功** — Music 再起動・HDMI 抜き差し・既定出力切替の全ケースで追従。HDMI 挿し直し直後の集約デバイス空回りに対し「2 秒の安定待ち＋ストール監視」で解決。**PoC フェーズ完了**。本番へ持ち越す注意点は `docs/poc-log.md` 末尾の「まとめ」参照
- 2026-09-19: **Xcode プロジェクト作成（xcodegen）・アプリ v0.1.0 動作確認済み** — MenuBarExtra の UI（ON/OFF・出力先 Picker・gain スライダー・対象アプリの追加/削除）から Music → HDMI の転送、音量変更、OFF で本体復帰まで実機で確認。PoC のロジックを `AudioEngine` / `ProcessMonitor` / `DeviceMonitor` / `SidecastController` に移植済み
- 2026-09-25: **v0.2.0** — 「ログイン時に起動」トグル（SMAppService）、`build.sh`（Release + dmg）/ `install.sh`（/Applications へ導入）、dmg 同梱の README.txt を追加。`/Applications/Sidecast.app` から運用開始
- 2026-09-26: **v0.2.0 の実機確認完了** — サインアウト→ログインで自動起動、Safari / Chrome を対象にした HDMI 出力（責任プロセス判定を含む）、HDMI 抜き差し、Music 再起動後の追従、すべて問題なし。要件はすべて満たした状態
- **次にやること**: 当面なし（日常利用で問題が出たら対応）。改善候補があれば: メニューに出力レベルメーター表示、対象アプリごとの ON/OFF、ハイレゾ時のレート追従
