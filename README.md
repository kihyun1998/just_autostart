# just_autostart

Launch a Dart command-line program or daemon at login on Windows and macOS.

Pure Dart. No Flutter dependency, no native sources to compile, and no step
where you open Xcode or hand-edit a Swift file.

## Status

**Early. No platform backend is wired up yet** — at this version every
operating system raises `UnsupportedPlatformException`. The cross-platform
surface below is stable enough to build against; the backends land next.

| Platform | Mechanism | State |
| -------- | --------- | ----- |
| Windows | Registry `Run` key, or Task Scheduler | Not implemented yet |
| macOS | launchd user agent | Not implemented yet |
| Everything else | — | Raises `UnsupportedPlatformException` |

## Usage

```dart
import 'package:just_autostart/just_autostart.dart';

final autostart = Autostart.forCurrentPlatform(
  AutostartConfig(
    appName: 'My Tool',
    label: 'com.example.mytool',
    executablePath: r'C:\Program Files\My Tool\mytool.exe',
    args: const ['--daemon'],
  ),
);

await autostart.enable();
await autostart.isEnabled();
await autostart.disable();
```

### You supply the executable path

`executablePath` is required and is never inferred. `Platform.resolvedExecutable`
looks like the obvious default, but under `dart pub global activate` it points
at the Dart runtime rather than at your tool — so inferring it would silently
register the wrong binary. Pass the path your installer used.

### An unsupported platform fails loudly

Every operation throws rather than returning quietly. In particular
`isEnabled()` never answers `false` on an unsupported platform: a quiet `false`
reads as "nothing registered yet" and would let you ship a toggle that can
never turn on.

## Documentation

This README grows as the backends land — including the Windows console-window
behaviour and the macOS sandboxing limitation, both of which affect which
mechanism you should choose.

Issues and progress: <https://github.com/kihyun1998/just_autostart/issues>
