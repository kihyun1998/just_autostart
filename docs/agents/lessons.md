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

## #12 — a struct that is the wrong size, and behaves perfectly — Step 5

**Rule it proves:** size a `Struct` from the **widest** union member, not the
member you use.

`VARIANT` was modelled as a 2-byte type tag, three reserved shorts, and one
machine word for the union — the shape every member this package constructs
actually needs. It compiled, allocated, zeroed and read back cleanly. It was
16 bytes; a real `VARIANT` is 24, because the widest union member is `BRECORD`
— `{PVOID pvRecord; IRecordInfo* pRecInfo;}`, two pointers.

Nothing about the wrong version looks wrong from Dart. What makes it dangerous
is that every `VARIANT` parameter is passed **by value**: `Connect` takes four
and `RegisterTaskDefinition` three. Eight bytes short means every argument
*behind* the variant lands in the wrong register or stack slot — so the failure
is not "the variant is wrong", it is `logonType`, `sddl` and the out-parameter
all silently shifting. That can fail as a crash, or as a *success* with
different meaning.

It was caught by `expect(sizeOf<Variant>(), 24)` before a single COM call ran.

**Consequence:** the FFI sacred path gets a size assertion for every struct
crossing the boundary by value, written from the C definition rather than from
the fields the code touches. And a size test is not enough on its own — see #16.

## #13 — the sibling's hardening did not apply, and copying it made things worse — Step 1

**Rule it proves:** a practice inherited from a reference is a *claim*, and Step
1 verifies claims against the real source — including the reference's own.

`just_font_scan` opens its DLLs by absolute path, `%SystemRoot%\System32\ole32.dll`,
commented as preventing DLL hijacking. This package copied it. The refuting lens
asked whether the premise held and the answer was on the machine:

```
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\KnownDLLs
  advapi32  advapi32.dll
  ole32     ole32.dll
  OLEAUT32  OLEAUT32.dll
```

Every DLL this package opens is a **KnownDLL**. The loader resolves those from a
section object mapped at boot and never consults the search path, so the bare
name was already unhijackable. The absolute path did not add safety — it
*subtracted* it, by introducing a directory read from an environment variable
where there had been no path at all.

It also retired a follow-up: "harden `registry.dart` to load `advapi32` by
absolute path" was recorded as technical debt and was never a defect.

**Consequence:** `loadKnownDll` loads by bare name and carries the KnownDLLs
reason. When a sibling's practice is adopted, its *premise* is checked here, not
assumed to travel.

## #14 — the type system cannot carry "synchronous" — Step 5

**Rule it proves:** when a contract cannot be expressed as a type, the
completeness pass has to look for the hole the type leaves.

COM's apartment is per-thread state and a Dart isolate is not pinned to an OS
thread across event-loop turns, so `withCom` opens and closes the apartment
around one **synchronous** block. That requirement was documented at length in
the doc comment, and the signature is `T withCom<T>(T Function() body)`.

`T` binds to `Future` as happily as to anything else. `withCom(() async { … })`
compiles. The body would return at its first `await`, the `finally` would tear
the apartment down immediately, and every COM release the body had arranged
would then run on a thread with no apartment. Heap corruption, not an exception.

No test would have found it, because no test would have written it — the trap is
for whoever adds `await` later, in the ticket that builds on this one.

**Consequence:** `withCom` now checks `result is Future` at runtime and throws.
Any invariant that the signature cannot state gets a runtime check, and the
completeness pass asks specifically what the types *fail* to say.

## #15 — the test that passes on CI and fails on the author's desk — Step 4

**Rule it proves:** a proof read out of a tool's human-facing output inherits
that output's locale.

`schtasks /query /v /fo LIST` is the readable way to confirm a registered task,
and the assertion `contains('On demand only')` was written against it. On a
Korean-locale Windows the same field reads `요청 시에만`. The test failed
locally and would have passed on GitHub's English `windows-latest` — the worst
direction, since CI would have certified an assertion that only ever held on
CI's machine.

`schtasks /query /xml ONE` emits the same document everywhere:

```xml
  <Triggers />
  <Actions Context="Author">
    <Exec><Command>…\dart.exe</Command></Exec>
  </Actions>
```

**Consequence:** every assertion against an external Windows tool reads a
machine-readable form. Localised output is for humans reading a terminal, never
for a test.

## #16 — an assertion that could not have failed — Step 5

**Rule it proves:** the completeness pass is a *mutation* question, not a
reading question. "Does this test cover the constant" is answered by changing
the constant.

`createTask` registers with `TASK_LOGON_INTERACTIVE_TOKEN` (3), and a test
asserted the resulting task runs as the current user — presented as covering
this package's "never needs elevation" invariant. The refuting lens set the
constant to `TASK_LOGON_NONE` (0) and the suite stayed green. Registering with
either value produced **byte-identical** XML, because with an empty `userId`
Task Scheduler normalises the logon type itself.

The assertion was true, and about something the constant did not control.

Twenty-four mutations were run over this change in total; that one and thirteen
others survived the first pass. Every survivor became a test, and none survives
now.

One caveat on the method, learned the same afternoon: **check that the mutation
applied.** A textual substitution that silently matches nothing leaves the code
untouched, the suite green, and the result reported as "survived" — which reads
as a coverage gap that is not there. That is the safe direction to fail, since
it prompts a look rather than false confidence, but a `grep -c` on the mutated
text costs nothing and removes the ambiguity.

**Consequence:** on the sacred paths, a test is only credited once a mutation of
the line it claims to cover turns it red. The comment on that test now says what
it does *not* pin, so the next reader does not re-inherit the belief.

## #17 — the third store, in a list I had already read — Step 5

**Rule it proves:** "existence is not enablement" is not a fact about *one*
second store. It is a shape, and the count is whatever the OS decided.

`CLAUDE.md` names the hazard, `theflow.md` lists it per surface, and this ticket
was written around it: `isEnabled()` reads the task's `Enabled` flag as well as
the registration, exactly as the `Run` key backend reads `StartupApproved`
alongside its value. Both the ticket and I treated that as the whole of it.

The refuting lens planted three tasks and asked what `isEnabled()` said:

| planted task | reported |
| --- | --- |
| logon trigger with `<Enabled>false</Enabled>`, task enabled | **`true`** |
| no `<Triggers>` at all | **`true`** |
| only a `<TimeTrigger>` dated 2099 | **`true`** |

A scheduled task's **trigger** carries its own enabled flag, and the Task
Scheduler UI disables a trigger through a different command from the one that
disables a task. Every row above is a state a user reaches by hand, in which the
program can never start and this package said it was on.

The list was right and I read it as a checklist of *stores already known*
instead of as a shape to go looking for again on a new surface.

**Consequence:** `RegisteredTask.startsAtLogon` reads the trigger collection,
and `isEnabled()` now has four conditions rather than three. The hidden-state
list gained the trigger flag — and on the next surface, the question to ask is
"how many stores does *this* one have", not "does it have the one I know about".

## #18 — the default that kills a daemon on day three — Step 1

**Rule it proves:** enumerate the hidden state by *reading it back*, not by
reading what gets written.

A fresh `ITaskService::NewTask` definition already carries
`ExecutionTimeLimit = PT72H`, and `AllowHardTerminate = true` beside it. Task
Scheduler stops a task that has been running for three days, and kills rather
than asks. For a **daemon** — the thing this package exists to start — that is a
defect that takes three days to appear and looks like a crash when it does.

It is invisible in the artefact everyone reads. The XML Task Scheduler exports
for such a task contains no `<ExecutionTimeLimit>` element at all; only
`ITaskSettings::get_ExecutionTimeLimit` reports it. The same probe found
`DisallowStartIfOnBatteries` and `StopIfGoingOnBatteries` both true — an
unplugged laptop never starts the program, and unplugging stops it — neither of
which appears in the XML either.

The probe was fifteen lines and ran before any of the ticket was written.

**Consequence:** `_setSettings` overrides all four. And the general form, now in
the hidden-state list: **an empty-looking `<Settings>` is not an absence.** For
any OS surface with defaults, read the defaults back from the API rather than
inferring them from what the serialised form shows.

## #19 — the assertion that could not see the field it was about — Step 5

**Rule it proves:** an unanchored `contains` on a document is not an assertion
about the part of it you meant.

`IPrincipal::put_UserId` is written on the FFI sacred path, where a wrong slot
index calls a real function through a valid pointer. The test asserted
`expect(xml, contains('<UserId>${currentUserSid()}</UserId>'))`.

Deleting the entire `put_UserId` call left all 304 tests green. Two independent
reasons, either of which was enough:

1. the task's XML carries `<UserId>` in **two** places — the principal and the
   logon trigger — and the unanchored match was satisfied by the trigger;
2. Task Scheduler defaults the principal's `UserId` to the registering user
   anyway, so even an anchored match could not distinguish *written* from
   *defaulted*.

The mutation matrix over all 31 vtable indices killed 30. This was the survivor.

**Consequence:** the assertion is anchored inside `<Principal>`, and the general
rule for this repo: when the proof is a document, match **within the element**
the code is responsible for. A whole-document `contains` proves the document
mentions something, which is rarely the claim.

## #20 — refusing one impossible combination and silently dropping the other — Step 6

**Rule it proves:** a "we refuse what we cannot honour" rule is a rule about the
*set*, and the member you leave out is the one that hurts.

`WindowsAutostartOptions` threw for `startupDelay` under the `Run` key, with the
reason written into the code: silently dropping the value would be worse than
refusing it. In the same class, `hideWindow: true` under the `Run` key was
accepted and dropped — and that is the **more** consequential of the two. The
caller is told autostart is configured and gets a black console window at every
login, which is the entire defect the other mechanism exists to fix.

It could not be refused as written, because `hideWindow` defaulted to `true` and
refusing the default would have refused every ordinary caller.

**Consequence:** `hideWindow` is `bool?`, defaulting to `null` — "whatever the
mechanism can do" — so an *explicit* `true` under the `Run` key is refused on the
same rule that already governed the delay. When a validation rule is written,
enumerate the whole set it claims to cover before the shape of one field decides
which members get enforced.

## #21 — the same identity, handed back in a different form — Step 4

**Rule it proves:** a round trip through an OS API is not a round trip through
its serialised form. Verify the read, not only the write.

`IPrincipal::put_UserId` is given the current user's SID, and the task's XML
stores exactly that:

```xml
<Principal id="Author">
  <UserId>S-1-5-21-3670707146-4230519492-3577509718-1001</UserId>
```

`IPrincipal::get_UserId` returns `User`. Task Scheduler resolves the SID to an
account name on the way out — so an ownership guard comparing the read value
against `currentUserSid()` can **never** match, and every task this package
wrote stopped being recognised as its own.

The XML was checked and looked right, which is exactly why this got as far as it
did. #12 had already recorded the mirror image — a trigger's `UserId` normalised
on *write* — and the lesson taken from it was about writes.

**Consequence:** `isCurrentUser` resolves whatever arrives back to a SID with
`LookupAccountNameW` and compares those, so `Name`, `DOMAIN\Name` and a SID all
answer the same question. And the general rule: when a guard depends on a value
that crosses an OS boundary in both directions, read it back through the *same
API the guard uses*, not through whatever the OS exports for humans.

## #22 — an assertion that cannot fail for the thing it names — Steps 4, 5

**Rule it proves:** an absence check needs a reader that distinguishes *absent*
from *empty*.

Three test files asserted their scratch task folder was removed on teardown with

```dart
expect(Process.runSync('schtasks', ['/query', '/tn', folder]).exitCode, isNot(0));
```

`schtasks /query /tn` exits non-zero for a folder that is **absent** and for one
that is merely **empty**. So the assertion passed for the leftover it existed to
catch — and a real leftover from an earlier failing run sat on the machine
undetected until an unrelated test tripped over it with `ERROR_DIR_NOT_EMPTY`.

Task Scheduler stores folders as real directories under `System32\Tasks`, so
`Directory(...).existsSync()` is a reader that can tell the two apart.

**Consequence:** all three files use it. And the general form, which is the
half worth keeping: **for a "this is gone" assertion, ask what the reader
returns for the failure state you are trying to detect.** If it returns the same
thing as success, the assertion is decoration.

## #23 — the composite that was never assembled in a test — Step 5

**Rule it proves:** testing the parts does not test the wiring, and the wiring
is where a two-line factory can invert the whole feature.

`WindowsAutostartBackend` cleans up whichever mechanism it was *not* given.
Wiring `other` to the same backend as `chosen` makes `enable()` register and
then immediately unregister — **autostart silently off, reported as success**.

Every integration test assembled the composite itself, so the factory in
`autostart.dart` was covered by nothing. Mutating `other: runKey` to
`other: taskScheduler` left all 343 tests green.

**Consequence:** a test that goes through the public factory and asserts *both*
`chosen` and `other`. The habit: when a class's correctness is "these two
collaborators are different things", the assembly point needs its own assertion —
the collaborators being individually correct says nothing about it.

## #24 — the guard whose rejecting branch one account cannot reach — Step 5

**Rule it proves:** say which half of a guard the tests actually prove, or the
comment becomes the lie the tests were supposed to prevent.

The Task Scheduler tree is machine-wide where `HKEY_CURRENT_USER` is not, so two
users of one installation have byte-identical executable paths — and this
change made a `Run` key caller touch the task tree for the first time. The guard
grew a second term: the task's principal must be the current user.

Proving it end to end needs a task belonging to somebody else, and **an
unelevated process cannot make one**. Measured, both ways: `schtasks /create
/xml` naming `S-1-5-19` is refused with access denied, and naming an
unresolvable SID is refused with "no mapping between account names and security
IDs".

Mutation testing then split the guard cleanly in two. Reading the **wrong
property** for the principal is killed — the read is live and correct. Deleting
the **term itself** survives — the rejecting branch is unreachable from one
account. The test comment had claimed the second, which was #19 happening again
in the same repository, three tickets later.

**Consequence:** the comment states both halves and names the measurement that
bounds the untestable one. `current_user_test.dart` covers the comparison
directly, which is the part a single account *can* prove.

## #25 — the completeness lens that sat for two hours on a permission prompt — Step 5

**Rule it proves:** a measurement that **changes machine state** is not
delegable. The main thread runs it, because only the main thread can be granted
the permission.

The Step 5 lens for #10 was briefed to verify `launchctl bootstrap` / `bootout`
semantics against the real command — the right question, handed to the wrong
place. Its last output before it was killed:

```
Now Corpus 2 — the real launchd reference. I'm on macOS, so I can measure directly.
```

It then stopped for **two hours**. `bootstrap` and `bootout` mutate the user's
live login session, so they need approval, and a background agent cannot answer
that prompt for itself. The read-only half of the brief (man pages, repo files)
had already completed; only the mutating half hung.

Running the same probe from the main thread took one command and answered
everything the lens was blocked on — including the finding that decided the
design: both commands **fail on their own happy paths** (exit 5 when already
loaded, exit 3 when not loaded), so an exit code cannot be the outcome report.

**Consequence:** a lens is briefed to read — sources, files, man pages — and to
*name* the runtime facts it needs. Measuring them is the main thread's job, and
the measurement is recorded in the issue where the lens's convergence claim can
rest on it. The split is not "who is capable" but "who can be granted
permission".

## #26 — the login test that would have passed while two lies went unnoticed — Step 4

**Rule it proves:** a verification of "does it work" needs the cases that must
**not** work, or it only measures the happy path.

The macOS backend's one manual login verification could have been a single
agent: register it, restart, see it run. That version passes, and everything it
touches is real — a `dart compile exe` binary, a genuine restart, launchd's own
`XPC_SERVICE_NAME` in the evidence.

It would also have said nothing about the two claims most likely to be wrong,
because both are claims that something *stays off*:

| planted | `isEnabled()` said | at login |
| --- | --- | --- |
| `launchctl disable`d (the Login Items veto) | false | did not run |
| plist `chmod 0666` after writing | false | did not run |

`isEnabled()` is a **prediction**; launchd is the truth. A one-agent test can
only ever confirm the optimistic half of that prediction — and optimism is
exactly this package's failure mode, the one `CLAUDE.md` names: a registration
that reports enabled while nothing launches. The negative controls are what
distinguish "reports true correctly" from "reports true always".

The permission case paid twice over. #13 was filed with the honest caveat that
only `bootstrap`'s refusal had been measured and *"the login path itself is not
separately measured"*. Planting that agent alongside the others cost nothing and
settled the caveat in the same restart.

**Consequence:** a manual verification is designed as a **matrix of predictions**
— every case where the answer must be *no* gets an agent too — and the write-back
records which predictions held, not that the feature worked.

---

## #27 — two mutations that only confirmed the tests I had already written — Step 5

**Rule it proves:** the test-trust gate is not satisfied by *a* mutation. A
mutation you invent after writing the test is drawn from the same model the test
came from, so it can only re-confirm what the test was already aimed at.

#15's new test group pinned that `taskExists` and `readTask` still agree. To
clear the gate I planted two wrong implementations and watched each die:

| mutation | killed by | and by nothing else |
| --- | --- | --- |
| return the task's `enabled` flag | 'for a task the user switched off' | ✓ |
| return `startsAtLogon` | 'for a task somebody else registered' | ✓ |

Clean results, and the group's comment then claimed that *"a later change that
quietly turned this into an ownership or enablement check would pass every other
test in this file"*.

The **refuting** lens — the second critic the bindings authorise only on a sacred
path — found the ownership half of that sentence false in one line:

```dart
bool taskExists(String name) => readTask(name)?.runsAsCurrentUser ?? false;
```

**All 63 tests passed.** The fixture named "somebody else registered" is planted
with `schtasks /create /tr` and no `/RU`, so its principal is *this* account and
`runsAsCurrentUser` is `true` for it. Measured while settling it: an unelevated
single account cannot plant anything else — a `GroupId` principal and an empty
`<Principal>` are both refused with access denied — so the state that would kill
the mutation is **unreachable from the suite by construction**, the #24 shape
recurring one ticket later.

Worse, and also from the refuter: neither of my mutations touched the code the
ticket actually changed. Reverting the headline change itself — restoring the
unconditional root fetch to `_withFolder` — left the suite green. **Both of
#15's acceptance criteria were invisible to all 428 tests.** The only evidence
for either is a benchmark and a cold-process probe, neither of which lives in
the repo.

*(Every suite total quoted in this file and in #28 predates #20, which removed
245 duplicated lines — 17 tests that had been running twice since the file was
created. The totals were what the runner reported at the time and the arguments
do not turn on the exact figure, so they are left as written rather than
retro-corrected. Read any of them as 17 higher than the same suite would report
today. That the numbers were inflated at all is #20's point.)*

The two mutations were not worthless: they proved the group was not vacuous. They
were just drawn from the same enumeration as the tests, so they could not reach
what that enumeration had missed.

**Consequence:** a mutation is written by asking *"what wrong implementation
would a later reader plausibly write?"* — not by inverting the assertion just
made. And when a test cannot reach a state, the comment says so with the
measurement that establishes it, rather than claiming a coverage the fixture
cannot deliver. This is the entry that earns the refuting lens its cost: the
gap-hunting lens graded the same area `CONFIRMED` on documentation only and did
not try the mutation.

**`taskExists` no longer exists** — do not grep for it. Both lenses also found
that nothing in `lib/` called it and that it was not exported, so the 67.8% it
had just gained was collected by tests alone while the second code path was
permanent. It was removed in the change after #15, on the ground `CLAUDE.md`
states directly: *existence is not enablement* is this package's recurring
hazard, so a fast and convenient way to ask the weaker question is a trap on a
class that can also delete another application's registration. The lesson above
outlives the method — it is about how the mutations were chosen, not about which
method they were aimed at.

---

## #28 — the number that reframed a ticket, and nobody measured the thing it named — Step 5

**Rule it proves:** a claim on a sacred path is credited only when a measurement
could have killed it. Measuring *something adjacent* and labelling it with the
claim's words is not that.

#16 was filed as a performance ticket. Re-measuring before starting showed the
saving had halved since #15, to **1.39 ms (8.0%)** on a rare, deliberate
operation — thin. So the ticket was **reframed** around safety instead: the
ownership guard ran in one COM session and the delete ran in the next, so the
window in which the name could come to mean a different task was "a whole COM
session, ~1.4 ms", and one session shrank it "about three orders of magnitude".

That sentence went into two doc comments and an issue comment. **It was wrong by
roughly 600×**, and the numbers that refute it were already on the same issue
page.

The window runs from `GetTask` to `DeleteTask`. It does not begin at the
predicate. Everything `_read` does after `GetTask` — `get_Enabled`,
`get_Definition`, the trigger walk, the principal, the actions — sits inside it
in **both** shapes, and `get_Definition` alone is 2.12 ms. From #15's own
breakdown:

| | |
| --- | --- |
| read tail after `GetTask`, unavoidable in both shapes | 2.40 ms |
| the second session this removes | ~1.6 ms |
| window before → after | ~4.0 ms → ~2.4 ms, **1.7×** |

Three things made it easy to get wrong, and all three are general:

1. **The quantity measured was not the quantity claimed.** `1.4 ms` is the
   *preamble*, measured in #15 for a different purpose. It was reused as "the
   window" because both are "the cost of a second session" in prose. Lessons #9
   is the same failure with a different subject.
2. **The reframing happened under pressure to save the ticket.** The performance
   case had just come apart; the safety case arrived to replace it and was not
   held to the same bar the number it replaced had just failed.
3. **The error flattered the change.** A claim that overstates a benefit on a
   path with no undo is the one direction that should trigger a re-measurement
   before it is written down, not after.

It was caught by the refuting lens, which the bindings authorise only on sacred
paths. This is the second consecutive ticket where that second lens found
something the gap-hunting lens graded as documentation-only — after #27, where
it broke a mutation claim.

**Consequence:** before a number goes into a doc comment, name the two events it
spans and check that the measurement you have spans the same two. And when a
ticket's stated justification collapses and a new one is reached for, the new one
is a *claim to verify*, not a rescue.
