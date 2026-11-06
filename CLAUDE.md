# Sidecast

macOS で「特定アプリの音声だけを HDMI 出力に流し、それ以外は通常の出力のまま」にするメニューバー常駐アプリ。
個人の週末プロジェクト。自分の Mac でだけ動けばよい（署名・公証・配布・他環境互換は考慮しない）。

- リポジトリ: https://github.com/takashick3/Sidecast（個人アカウント takashick3。業務アカウントでコミットしない。hook が `user.email` を検査する）
- bundle ID: `org.takashick.Sidecast`、対応 OS: macOS 27 以降、ライセンス: MIT
- 現状: **v0.2.0 を `/Applications/Sidecast.app` で常用中。要件はすべて充足し、次の予定なし**（改善候補: 出力レベルメーター、対象アプリごとの ON/OFF、ハイレゾ時のレート追従）

## ドキュメント
- `docs/design.md` — 要件・方式（Core Audio Process Taps）・アプリ指定・動的追従の決定事項
- `docs/poc-log.md` — PoC 1〜5 の観測結果と、本番へ持ち越した注意点（末尾「まとめ」）
- `docs/history.md` — PoC の計画と日付付きの作業ログ

## 作業ルール
- コミットメッセージは英語の簡潔な命令形（例: `Add process dump PoC`）。push 先は `git@github.com:takashick3/Sidecast.git`（HTTPS 可）
- 変更を伴う操作は事前に確認する（`.claude/settings.local.json` の `defaultMode: default`）。調査・ビルドのみは不要

## 実装時の制約
- `AudioEngine` の IOProc は**リアルタイム安全**：ロック・アロケーション・Swift の参照型操作・ログ出力・ObjC メッセージ送信をしない。gain は UI → IOProc へ `Atomic<Float>`（Synchronization framework）で渡す
- IOProc ブロックは `nonisolated` 関数で生成する（MainActor 推論で SIGTRAP になる）
- `CATapDescription` は実質イミュータブル。対象プロセスや HDMI の出入りではタップと集約デバイスを破棄して作り直す。HDMI 挿し直し直後は「2 秒の安定待ち＋ストール監視」
- `com.apple.WebKit.GPU` は他アプリ配下にも同名があるため bundle ID 単体で判定せず、責任プロセス（`responsibility_get_pid_responsible_for_pid`）で絞る
- Info.plist の `NSAudioCaptureUsageDescription` が必要（初回に TCC 許可）

## ビルド・配布・インストール
- `Sidecast/build.sh` — xcodegen → Release ビルド → `dist/Sidecast-<version>.dmg`（`dist/` は git 管理外）
- `Sidecast/install.sh` — build.sh を実行し `/Applications/Sidecast.app` に入れて起動し直す。**常用・ログイン項目はこのコピーから**
- バージョンは `Sidecast/project.yml` の `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` が唯一の定義。リリースは `/release-check`
- Debug ビルドだけなら `cd Sidecast && xcodegen generate && xcodebuild -project Sidecast.xcodeproj -scheme Sidecast -configuration Debug -derivedDataPath build build`（`.xcodeproj` と `build/` は git 管理外）
- ログは `log show --predicate 'subsystem == "org.takashick.Sidecast"' --info --last 10m`（info レベルなので `--info` が必要）
