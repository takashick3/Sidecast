# Sidecast

macOS menu bar app that routes the audio of selected apps (e.g. Music.app, browsers)
to an HDMI output device while everything else keeps playing on the normal output.

- Implemented with Core Audio **Process Taps** (`CATapDescription` + aggregate device),
  no virtual audio driver / HAL plug-in.
- Personal weekend project. Targets macOS 27+ only. Not signed, notarized or distributed.
- Design notes and work rules: [CLAUDE.md](CLAUDE.md). PoC results: [docs/poc-log.md](docs/poc-log.md).

## Requirements

- macOS 27 or later, Xcode 27, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An HDMI (or any non-default) output device. The app never taps when the selected device is the system default output.
- First run asks for the "System Audio Recording" permission (Process Taps).

## Build & run

```
cd Sidecast
xcodegen generate
xcodebuild -project Sidecast.xcodeproj -scheme Sidecast -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Sidecast.app
```

## Usage

1. Click the waveform icon in the menu bar.
2. Pick the output device (e.g. your HDMI monitor).
3. "Add from apps currently playing audio" lists running audio processes grouped by their host app
   (e.g. `Safari ▸ GPU`); pick the ones to route.
4. Turn the switch on. The selected apps play on the HDMI device and go silent on the normal output;
   the slider adjusts the HDMI volume (software gain).

The routing follows app restarts, HDMI hot-plug and default-output changes automatically.

## Layout

```
PoC/        Swift Package (executable CLIs) used to validate each building block
Sidecast/   App: project.yml (xcodegen) + sources
docs/       PoC log and other documents
```

## License

MIT — see [LICENSE](LICENSE).
