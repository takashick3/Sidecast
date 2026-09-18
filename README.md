# Sidecast

macOS menu bar app that routes the audio of selected apps (e.g. Music.app, browsers)
to an HDMI output device while everything else keeps playing on the normal output.

- Implemented with Core Audio **Process Taps** (`CATapDescription` + aggregate device),
  no virtual audio driver / HAL plug-in.
- Personal weekend project. Targets macOS 27+ only. Not signed, notarized or distributed.
- Design notes and work rules: [CLAUDE.md](CLAUDE.md). PoC results: [docs/poc-log.md](docs/poc-log.md).

## Layout

```
PoC/        Swift Package (executable CLIs) used to validate each building block
Sidecast/   Xcode project (created after the PoC phase)
docs/       PoC log and other documents
```

## License

MIT — see [LICENSE](LICENSE).
