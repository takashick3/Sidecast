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
