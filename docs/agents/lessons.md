# lessons (just_autostart)

Per-incident evidence for the rules in [`theflow.md`](theflow.md). Each entry is
a real incident with the artifact that proves it — the rules read as
abstractions without these.

Indexed by the step whose rule it gives teeth to.

---

## #1 — A summarizing fetch invented native platform folders — Step 1

**Rule it proves:** read whole files from raw source; never use a summarizing
fetch on a reference repo.

A summarizing fetch of `leanflutter/launch_at_startup` reported the repository
as a "hybrid plugin" containing `windows/` (C++), `macos/` (Swift) and `linux/`
directories, and described the plugin as implemented through method channels
into native code.

The actual tree (`gh api repos/leanflutter/launch_at_startup/git/trees/main?recursive=1`)
contains **no such directories**. Outside `example/`, the entire package is nine
files: seven Dart sources, `pubspec.yaml`, and docs. Its only non-Flutter
dependency is `win32_registry`.

**Cost had it stood:** the whole premise of this project — "can this be done as a
pure Dart package?" — would have been answered wrong. The summary made a package
that is *already* pure Dart on Windows look like it required a C++ toolchain.

**Why the summary failed this way:** it read the README's macOS setup section
(which instructs the *consumer* to add Swift code to their own Xcode project) and
attributed that code to the package.

---

## #2 — The reference behaves differently on each platform, and fails silently on one — Steps 1, 2

**Rule it proves:** prior art is cross-checked, not obeyed; and a divergence is
only a direction once you have read both corpora.

`launch_at_startup` on **Windows** overrides the user's veto unconditionally:

```dart
final bytes = Uint8List(12);
bytes[0] = 2;                    // 2 = enabled
_startupApprovedRegKey.createValue(RegistryValue.binary(appName, bytes));
```

On **macOS** it has no implementation at all — it delegates to
`sindresorhus/LaunchAtLogin`, whose modern path is:

```swift
private static var isEnabledModern: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
        do {
            if newValue { … try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            logger.error("Failed to …")     // swallowed
        }
    }
}
```

Three things follow directly from those lines. `register()` has **no force
option** — Apple provides no way to overrule a user who disabled the app in
Login Items. The failure is **swallowed into a log**, so the caller cannot
distinguish success from failure. And because the getter is `status == .enabled`,
an app that sets `isEnabled = true` can read `isEnabled` on the next line and
still get `false`, with nothing raised.

**How it was settled:** by reading the raw Swift, after an argument about which
behaviour was "correct" had already run for two exchanges without evidence. The
source ended it in one file.

**What was adopted and what was not:** the Windows override behaviour was adopted
`[product]` for ecosystem consistency; the swallowed error was rejected as a
defect. That split is the tie-breaker in `theflow.md` doing its job.

---

## #3 — An unquoted path in the reference breaks on any install directory with a space — Step 1

**Rule it proves:** prior art is a cross-check, not an authority.

`launch_at_startup`'s Windows implementation builds the registry value as:

```dart
_registryValue = args.isEmpty ? appPath : '$appPath ${args.join(' ')}';
```

Windows parses that value with its own command-line rules, so
`C:\Program Files\My Tool\mytool.exe` is truncated at the first space. The
failure is invisible in development (repository paths rarely contain spaces) and
appears on a user's machine at their next login.

**Consequence here:** the executable path is quoted **unconditionally** in this
package, and the encode/decode pair is pure so the space cases are pinned by
tests that need no registry.

---

## #4 — `docs/` collides with pub's reserved layout name and blocks publishing — Step 6

**Rule it proves:** `.pubignore` is load-bearing; the publish gate finds things
no other gate does.

Creating `docs/agents/` for agent workflow configuration made
`dart pub publish --dry-run` refuse outright:

```
* Rename the top-level "docs" directory to "doc".
  The Pub layout convention is to use singular directory names.
Sorry, your package is missing a requirement and can't be published yet.
```

**Fix:** a `.pubignore` excluding `docs/` and `.github/` — agent configuration is
repo tooling, not package documentation, and should never have been in the
archive.

**The trap inside the fix:** `.pubignore` *replaces* `.gitignore` for archive
purposes, so `.dart_tool/` and `pubspec.lock` had to be repeated in it or they
would have started shipping.

**Latency:** introduced during repo setup, found two steps later by a dry run
that was not part of the ticket. Nothing else would have caught it before the
first publish attempt.

---

## #5 — 31 green tests while a user-facing message contradicted itself — Steps 4, 6, 7

**Rule it proves:** documentation and user-facing strings are read, not asserted;
and `dart test` does not run `example/`.

With `dart analyze --fatal-infos` clean and 31 tests passing, running the example
printed:

```
just_autostart has no backend for "windows". Supported platforms are Windows and macOS.
```

The sentence contradicts itself. The tests asserted how the message was
*assembled* — that it contains the operating system name — which is exactly what
a test can check. Whether the assembled sentence is *true* is not assertable, and
no test was ever going to catch it.

**Fix:** the message stopped enumerating supported platforms. That list belongs
in documentation, where it cannot drift out of step with which backends are
actually wired up.

**Standing gap:** CI still does not execute `example/`, so this class of defect
remains reachable. Recorded in `theflow.md` Step 7 rather than closed.

---

## #6 — An unverified assumption was promoted into a design premise — Reasoning habits

**Rule it proves:** "unconfirmed ≠ absent" — and the inverse, that a cleared
concern needs its validity condition.

While designing the boundary rule, the claim *"both platforms are technically
overridable"* was stated and then built on: an entire `force`-flag API design
rested on it.

Windows was checked (`HKCU` is writable unprivileged). **macOS was never
checked.** Reading `LaunchAtLogin`'s source afterwards showed `SMAppService`
offers no force option at all (#2), so the premise was false on one of the two
platforms the design covered.

**What it cost:** two exchanges of argument that a single file read settled, and
a proposed API surface that would have been asymmetric across platforms.

**The asymmetry that makes this rule pay:** re-confirming costs one fetch;
publishing an API on a wrong premise costs a breaking change.

---

## #7 — `0x80000001` is the wrong `HKEY_CURRENT_USER` on 64-bit — Step 1

**Rule it proves:** verify constants against real source; a value you can recite
is still a value you have not checked.

The obvious spelling of the predefined handle is the documented constant:

```dart
const hkeyCurrentUser = 0x80000001;   // wrong
```

`package:win32`'s generated source says otherwise (`constants.g.dart:4613`):

```dart
final HKEY_CURRENT_USER = HKEY(Pointer.fromAddress(-2147483647));
```

The Win32 header defines it as `((HKEY)(ULONG_PTR)((LONG)0x80000001))`. The
`(LONG)` cast makes the value signed *before* it widens, so on 64-bit the handle
is `0xFFFFFFFF80000001`. Passing the unsigned literal hands Windows a handle it
does not recognise.

**Why it would not have been caught quickly:** every call would fail with the
same generic status, and the natural suspect is the FFI signature, not the
constant that "obviously" matches the documentation.

---

## #8 — Two test files sharing one scratch key destroyed each other — Step 7

**Rule it proves:** run the *full* suite, not the file you are working on.

`registry_test.dart` and `windows_run_key_backend_test.dart` both used a scratch
subkey under `HKCU\Software\just_autostart_test`, and both deleted that whole
parent in `tearDownAll`. Each file passed in isolation. `dart test` runs files
concurrently, so whichever finished first deleted the other's data mid-run:

```
Failing tests:
  test\windows\registry_test.dart: WindowsRegistry deletes a value it wrote
```

**Fix:** each file owns a distinct top-level scratch tree
(`just_autostart_test_registry`, `just_autostart_test_backend`) and deletes only
its own.

**The general shape:** integration tests that reach real OS state share a
namespace with each other, exactly as the `Run` key is shared with other
applications. The sacred path this package guards for third parties applies to
its own test files too.

---

## #9 — A measurement that answered the wrong question, and read the same either way — Step 4

**Rule it proves:** beware a measurement that can misread itself.

Deciding whether Task Scheduler could hide a console window, the first probe
asked:

```dart
final hwnd = getConsoleWindow();
'hwnd=$hwnd hasConsole=${hwnd != 0}'
```

Both candidate routes reported `hasConsole=true`, and the conclusion drawn was
"neither hides the window."

`GetConsoleWindow()` returns a handle whenever the process **has** a console. A
console created with `SW_HIDE` still has one. The probe was asking "does a
console exist", which is true in every case, rather than "is its window visible".

Re-measured with `IsWindowVisible(GetConsoleWindow())`, the two routes separated
immediately:

```
WSCRIPT hidden wrapper -> hwnd=3411056 visible=false
TASK InteractiveToken  -> hwnd=6884938 visible=true
```

**What gave it away:** the two routes agreeing. A measurement that returns the
same answer for a case known to differ is reporting its own blind spot, not the
world.

---

## #10 — "The documentation lists the properties" is not the same as enumerating them — Step 1

**Rule it proves:** verify against the real thing, not against a summary of it —
and the API surface is a real thing you can query.

Working from the documented `IExecAction` — `Path`, `Arguments`,
`WorkingDirectory`, `Id` — the conclusion was recorded that Task Scheduler
exposes no window-style setting, and therefore could not hide a console window
without elevation. That conclusion was reported to the maintainer as measured.

Enumerating the live COM object took one line:

```powershell
$svc = New-Object -ComObject Schedule.Service; $svc.Connect()
$def = $svc.NewTask(0); $act = $def.Actions.Create(0)
$act | Get-Member -MemberType Property | ForEach-Object { $_.Name }
```
```
Arguments
HideAppWindow      <-- undocumented
Id
Path
Type
WorkingDirectory
```

Registering with `HideAppWindow = true`, unelevated, produced `visible=false`.
The reported conclusion was wrong and the ticket it would have closed off was
viable all along.

**Cost had it stood:** #6 would have been rescoped or cancelled on a false
finding, and the package would have shipped without the feature the ticket exists
for.

---

## #11 — Task Scheduler exports XML it will not import — Step 1

**Rule it proves:** a round trip is two halves, and doing only one of them proves
nothing.

Having found `HideAppWindow` through COM, the natural next step was to keep the
simpler `schtasks /create /xml` implementation and just add the element — Task
Scheduler *exports* it, after all:

```xml
      <HideAppWindow>true</HideAppWindow>
```

Import refuses it, at every schema version:

```
ERROR: The task XML contains an unexpected node.
(6,364):HideAppWindow
version 1.3 -> exit=1
version 1.4 -> exit=1
version 1.5 -> exit=1
```

So a task Windows itself exported cannot be recreated from that export. Nothing
documents this; it appears only if you do the export **and** the import.

**Consequence:** the entire implementation route changed from shelling out to
`schtasks` to hand-written COM — roughly ten interfaces instead of one process
spawn. Recorded in ADR-0001, and the reason #6 was split into #6a and #6b.
