# just_autostart

Launch a Dart command-line program or daemon at login on Windows and macOS.

Pure Dart. No Flutter dependency, no native sources to compile, and no step
where you open Xcode or hand-edit a Swift file.

## Status

**Early, and Windows-only so far.** The cross-platform surface is stable enough
to build against; macOS is next.

| Platform | Mechanism | State |
| -------- | --------- | ----- |
| Windows | Registry `Run` key | **Works** |
| Windows | Task Scheduler (hidden window, delayed start) | **Works** |
| macOS | launchd user agent | Not implemented yet |
| Everything else | — | Raises `UnsupportedPlatformException` |

## Choosing a Windows mechanism

**Only Task Scheduler can start your program without a console window.** A
`dart compile exe` output is a console-subsystem executable and the subsystem is
fixed at compile time, so whether a window appears is decided by the process
that launches you — never by anything your program does at runtime.

| | Registry `Run` key | Task Scheduler |
| --- | --- | --- |
| Console window at login | **Always visible** | **Hidden**, or visible on request |
| Delayed start | no | yes |
| Where the user sees it | Task Manager → Startup apps | Task Scheduler |
| Scope | per user (`HKCU`) | machine-wide task tree |
| Needs elevation | no | no |

There is **no automatic fallback** between them: they trade off differently and
the choice is yours.

```dart
final autostart = Autostart.forCurrentPlatform(
  config,
  windows: const WindowsAutostartOptions(
    mechanism: WindowsAutostartMechanism.taskScheduler,
    // Optional: wait before starting, so you do not compete with the rest of
    // the login sequence. Resolution is one second.
    startupDelay: Duration(seconds: 30),
  ),
);
```

The default is the `Run` key — simpler, per-user, and visible to the user where
they expect it. Switch to Task Scheduler when the console window matters.

A combination that cannot be honoured is **refused, not ignored**: asking for
`hideWindow: true` or a `startupDelay` under the `Run` key throws
`ArgumentError` rather than silently registering something else.

> **Two users, one machine.** The `Run` key is per-user and isolates them for
> free. The Task Scheduler tree is machine-wide, so two users of the same
> application collide on the same task name — the second registration fails with
> access denied rather than overwriting the first.

### Switching mechanisms is handled for you

If version 1 of your tool registered through the `Run` key and version 2 asks
for Task Scheduler, `enable()` removes the old registration as it makes the new
one — otherwise the user gets your program **twice** at every login, with the
console window still there. `disable()` clears both mechanisms for the same
reason: "off" has to mean off.

Two limits, both deliberate:

- Cleanup removes a registration only when it names the **same executable
  path**. Matching on the display name instead would let this package delete a
  third party's autostart out of a namespace it shares. So if your installer
  puts each version in its own directory, your own older registration is not
  removed for you — remove it at uninstall time.
- If the old registration cannot be removed, `enable()` throws
  `MechanismCleanupException` **after** the new one is in place. Autostart is
  on, and the program may launch twice; that is a different situation from
  "could not enable", which is why it is a different exception.

### The user can override you, and `isEnabled()` says so

On both mechanisms Windows keeps the user's own decision **somewhere other than
the registration**, and `isEnabled()` reads every one of those stores — so it
reports `false` for something the user has switched off, and your toggle will
not contradict what Windows is showing them.

- **`Run` key** — a second registry key records a user switching the entry off
  in Task Manager's "Startup apps" tab.
- **Task Scheduler** — the task has an enabled flag, *and* its trigger has a
  separate one. Disabling either from the Task Scheduler UI stops the program
  starting while leaving the registration untouched.

`enable()` **clears** that veto on both, matching `launch_at_startup`. Call it in
response to a user action, not on every launch.

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

This README grows as the backends land — the macOS sandboxing limitation is
still to come, and it affects which mechanism you should choose there.

Issues and progress: <https://github.com/kihyun1998/just_autostart/issues>
