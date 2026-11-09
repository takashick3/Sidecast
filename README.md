# Sidecast

[![Sponsor](https://img.shields.io/github/sponsors/takashick3?label=Sponsor&logo=GitHub&color=ea4aaa)](https://github.com/sponsors/takashick3)

[日本語](#日本語) | [English](#english)

## 日本語

macOS のメニューバーに常駐し、指定したアプリ（ミュージック.app やブラウザなど）の音声だけを
HDMI 出力へ流すアプリです。それ以外の音はふだんの出力のまま鳴ります。

- Core Audio の **Process Taps**（`CATapDescription` ＋集約デバイス）で実装しています。
  仮想オーディオドライバや HAL プラグインは使いません。
- 個人の週末プロジェクトです。対象は macOS 27 以降のみで、署名・公証・配布はしていません。
- 設計: [docs/design.md](docs/design.md)。作業ルール: [CLAUDE.md](CLAUDE.md)。PoC の結果: [docs/poc-log.md](docs/poc-log.md)。

### 動作環境

- macOS 27 以降、Xcode 27、[xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- HDMI など、システムの既定出力以外の出力デバイス。選んだデバイスが既定出力と同じときはタップしません。
- 初回起動時に「システムオーディオ録音」の許可を求められます（Process Taps に必要）。

### ビルド・パッケージ化・インストール

```
cd Sidecast
./build.sh     # xcodegen → Release ビルド → dist/Sidecast-<version>.dmg
./install.sh   # build.sh を実行し、/Applications/Sidecast.app にコピーして起動し直す
```

ビルドし直したあとも「ログイン時に起動」（SMAppService）を効かせたい場合は、`/Applications` から起動してください。
Debug ビルドだけなら `xcodegen generate && xcodebuild -project Sidecast.xcodeproj -scheme Sidecast -configuration Debug -derivedDataPath build build` です。

### 使い方

1. メニューバーの波形アイコンをクリックします。
2. 「出力先」で出力デバイス（HDMI モニターなど）を選びます。
3. 「音を出しているアプリから追加…」を開くと、音を出しているプロセスがホストアプリごとに並びます
   （例: `Safari ▸ GPU`）。流したいものを選びます。
4. スイッチをオンにします。選んだアプリの音は HDMI デバイスから鳴り、通常の出力では無音になります。
   スライダーで HDMI 側の音量（ソフトウェアゲイン）を調整できます。
5. 「ログイン時に起動」をオンにすると、ログイン項目に登録されます。

アプリの再起動、HDMI の抜き差し、既定出力の切り替えには自動で追従します。

### 構成

```
PoC/        各要素の検証に使った Swift Package（実行可能な CLI 群）
Sidecast/   アプリ本体: project.yml（xcodegen）とソース
docs/       設計・PoC ログなどのドキュメント
```

### スポンサー

Sidecast が役に立ったら、[GitHub Sponsors](https://github.com/sponsors/takashick3) から開発を支援していただけるとうれしいです。

### ライセンス

MIT — [LICENSE](LICENSE) を参照してください。

---

## English

macOS menu bar app that routes the audio of selected apps (e.g. Music.app, browsers)
to an HDMI output device while everything else keeps playing on the normal output.

- Implemented with Core Audio **Process Taps** (`CATapDescription` + aggregate device),
  no virtual audio driver / HAL plug-in.
- Personal weekend project. Targets macOS 27+ only. Not signed, notarized or distributed.
- Design: [docs/design.md](docs/design.md). Work rules: [CLAUDE.md](CLAUDE.md). PoC results: [docs/poc-log.md](docs/poc-log.md).

### Requirements

- macOS 27 or later, Xcode 27, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An HDMI (or any non-default) output device. The app never taps when the selected device is the system default output.
- First run asks for the "System Audio Recording" permission (Process Taps).

### Build, package, install

```
cd Sidecast
./build.sh     # xcodegen + Release build + dist/Sidecast-<version>.dmg
./install.sh   # build.sh, then copy to /Applications/Sidecast.app and relaunch
```

Run the app from `/Applications` if you want "Launch at login" (SMAppService) to keep working across rebuilds.
For a plain Debug build: `xcodegen generate && xcodebuild -project Sidecast.xcodeproj -scheme Sidecast -configuration Debug -derivedDataPath build build`.

### Usage

The app's UI is in Japanese; the English names below are translations.

1. Click the waveform icon in the menu bar.
2. Pick the output device (出力先, e.g. your HDMI monitor).
3. "Add from apps currently playing audio" (音を出しているアプリから追加…) lists running audio processes
   grouped by their host app (e.g. `Safari ▸ GPU`); pick the ones to route.
4. Turn the switch on. The selected apps play on the HDMI device and go silent on the normal output;
   the slider adjusts the HDMI volume (software gain).
5. "Launch at login" (ログイン時に起動) registers the app as a login item.

The routing follows app restarts, HDMI hot-plug and default-output changes automatically.

### Layout

```
PoC/        Swift Package (executable CLIs) used to validate each building block
Sidecast/   App: project.yml (xcodegen) + sources
docs/       Design, PoC log and other documents
```

### Sponsor

If Sidecast is useful to you, you can support its development via
[GitHub Sponsors](https://github.com/sponsors/takashick3).

### License

MIT — see [LICENSE](LICENSE).
