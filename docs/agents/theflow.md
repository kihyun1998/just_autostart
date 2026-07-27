# theflow bindings (just_autostart)

Project-specific data for the `theflow` skill. The skill holds the portable
*method*; this file holds the *bindings*. Per-incident evidence lives in
[`lessons.md`](lessons.md).

Identity lives in [`../../CLAUDE.md`](../../CLAUDE.md). There is **no
`CONTEXT.md` and no `docs/adr/` yet** — `docs/agents/domain.md` declares them as
the single-context layout, and `/domain-modeling` creates them lazily. Until one
exists, "the decision trail" below means the issue tracker.

## Reasoning bindings (project-wide)

**Prior art cross-checked throughout:** `leanflutter/launch_at_startup` (the
package this one replaces for pure-Dart consumers),
`sindresorhus/LaunchAtLogin` (what that package delegates to on macOS),
`package:win32` / `win32_registry` (how the ecosystem marshals Win32 from Dart),
and the sibling repos named in the routing table.

**Tie-breaker — behaviour follows prior art; facts follow measurement.**
User-visible behaviour and API convention follow the established package so a
consumer arriving from `launch_at_startup` is not surprised. But *how the
operating system actually behaves* is settled by our own measurement, and a
measurement always outranks a sentence in someone's README — including one in
the reference's own source. The two halves are separable in practice: we adopted
`launch_at_startup`'s override behaviour (below) **and** rejected its swallowed
error in the same breath, because the first is a convention and the second is a
defect the source showed plainly.

**Record which type each decision was.** A derivation falls to a better
derivation; a product judgement falls only to the person who made it. Decisions
in this file are tagged `[product]` where the maintainer chose, so a later
adversarial pass does not reopen a call that was theirs.

## The recurring failure here: existence is not enablement

Every surface this package writes to has a **second store holding the user's
veto**, and it is never the store you just wrote:

| You wrote | The user's veto lives in |
|---|---|
| `Run` key value | `StartupApproved\Run` (12-byte value, **first byte parity**) |
| a Startup-folder shortcut | `StartupApproved\StartupFolder` |
| a scheduled task | the task's own enabled/disabled flag |
| a LaunchAgent plist | launchd's disable overrides, outside the plist |

A check that reads only the first column reports "enabled" for something that
will never launch. **Every read path reads both stores; every write path
maintains both.** This is also why the reference implementation is a war story
rather than a model — see [`lessons.md`](lessons.md) #2.

## Crate / module map

**Pure Dart, single package.** No Flutter dependency, no native sources, no
`windows/`/`macos/` trees, no `plugin` declaration. No member carries its own
`pubspec.yaml`, so there is **no out-of-workspace member** — the usual Step 7
blind spot does not exist here. The real blind spot is per-runner (Step 7).

| Module | Role |
|---|---|
| `lib/just_autostart.dart` | the public surface; the export list *is* the API contract |
| `lib/src/autostart.dart` | `Autostart` — the facade. Selects a backend once at construction and delegates unchanged, so a backend's failures reach the caller as thrown |
| `lib/src/autostart_backend.dart` | `AutostartBackend` — the seam. Three methods, identical across platforms; the differences live in *where* a registration is stored, never in *what operations exist* |
| `lib/src/autostart_config.dart` | `AutostartConfig` — the validated value object. `executablePath` is required and never inferred |
| `lib/src/autostart_platform.dart` | `resolveAutostartPlatform` — OS name → backend, **as a pure function of the string**, so every arm is testable off-host |
| `lib/src/exceptions.dart` | sealed `AutostartException` hierarchy. Sealed on purpose: adding a failure mode makes the analyzer point at every exhaustive switch |
| `lib/src/backends/` | one backend per platform. `unsupported_backend.dart` throws from all three operations rather than returning a quiet `false` |
| `lib/src/backends/windows/run_command_line.dart` | pure encode/decode of the registry `Run` value. The **canonical form** (path always quoted) is what lets `disable()` tell our entries from a third party's |
| `lib/src/backends/windows/startup_approval.dart` | pure encode/decode of the `StartupApproved\Run` byte format — the store holding the **user's** veto, as opposed to the registration |
| `lib/src/backends/windows/registry.dart` | hand-written `advapi32` bindings and `RegistryLocation` — the backend's **only** seam. No interface over it and no fake of it: the marshalling *is* the dangerous part |
| `lib/src/backends/windows/windows_run_key_backend.dart` | the `Run` key backend |
| `example/` | the **only in-repo consumer seam** — reaches the package through the public API only. No separate `pubspec.yaml`, so `dart analyze` covers it but `dart test` does **not** run it (see Step 7) |

## Hidden-state list

Read this **before** touching domain semantics. These are the states the OS
tracks that a first-principles model omits because the model "looks correct".
Add to this list when a pass finds another.

**Windows**

- `StartupApproved\Run` holds a **12-byte binary** value per entry. **Odd first
  byte = the user disabled it**; even, empty, and absent all mean enabled. Format
  is undocumented by Microsoft. **Measured on a real machine (#4):** enabled
  entries are `02` followed by eleven zero bytes; a user-disabled entry is `03`,
  three zero bytes, and then a little-endian **FILETIME** recording when it was
  switched off. The reference implementation's comment describes only the parity
  byte.
- **`HKEY_CURRENT_USER` is `Pointer.fromAddress(-2147483647)`, not
  `0x80000001`.** The Win32 header casts to `(LONG)` before widening to
  `ULONG_PTR`, so the 64-bit handle is sign-extended to `0xFFFFFFFF80000001`.
  The unsigned literal produces a handle Windows does not recognise.
- **`RegQueryValueExW` does not guarantee a null terminator** on string values;
  `RegGetValueW` does. A value another program wrote without one is a read past
  the end. Read with `RegGetValueW`.
- **`StartupApproved` has a sibling key, `StartupApproved\StartupFolder`** —
  the veto store for the Startup-*folder* `.lnk` mechanism, confirmed present on
  a real machine. Not touched by the `Run` backend, but the mechanism work will
  meet it.
- **`Policies\Explorer\DisableCurrentUserRun` = 1 makes Windows ignore the whole
  HKCU `Run` key.** A *third* store where `isEnabled()` can report true and
  nothing launches. Absent on the machine probed, and not read by this package
  or by `launch_at_startup` — repo and reference agree, so it is recorded as a
  known limitation rather than handled.
- The `Run` key is a **shared namespace keyed by value name**. Deleting the wrong
  name deletes *another application's* autostart, unrecoverably. Same for the
  Task Scheduler folder.
- The `Run` value is a **single command-line string** parsed by Windows' own
  rules. Quoting the executable path is not optional — an unquoted path with a
  space is silently truncated at the space.
- A scheduled task can **exist while disabled**. Existence ≠ enabled.
- A `dart compile exe` output is a **console-subsystem PE**; the subsystem is
  fixed at compile time, so the registry mechanism shows a console window at
  every login and no runtime API can suppress it.
- MSIX / packaged apps take an entirely different path. Out of scope here, but it
  is state that exists and a report from a packaged app is not a defect in this
  package.

**macOS**

- launchd's **disable overrides live outside the plist**, in root-owned state.
  Plist existence ≠ the agent will run.
- The **label doubles as the plist filename**, so a path separator in it is a
  deletion hazard — validated in `AutostartConfig`, not in one backend.
- `SMAppService` registers the *enclosing `.app` bundle*. A bare Mach-O from
  `dart compile exe` has no bundle, so that API cannot serve this package's
  target — in any language. This is why the mechanism is a LaunchAgent.

**Both**

- `Platform.resolvedExecutable` under `dart pub global activate` points at the
  **Dart runtime**, not at the caller's tool. This is why `executablePath` is a
  required argument and inference is refused.
- A registration can point at a **stale path** after a reinstall. Existence ≠
  correctness; a read compares the registered path structurally.

## Step 1 — reference routing table

**No sibling repo touches advapi32, the registry, `LaunchAgents`, or
`launchctl`** (checked across 98 repos in `../`). The two core mechanisms have
*no in-family prior art* and are verified against external source only. The
siblings that do exist cover the *technique*, not the domain — route accordingly.

| Change type | Real source to read |
|---|---|
| **Windows registry semantics** | Microsoft Learn for the `Reg*W` functions, read raw. Cross-check the marshalling against `win32_registry`'s source. `StartupApproved` byte semantics: `launch_at_startup`'s Windows implementation — **as prior art, not as authority** (it has a real defect; lessons #3) |
| **Windows COM (`IShellLink`)** | sibling **`just_font_scan`** — real `ole32.dll` COM from pure Dart, in production. Then `package:win32`'s `examples/shortcut.dart` |
| **macOS launchd plist** | Apple's `launchd.plist(5)` man page. `launch_at_startup` has **no macOS implementation** to read — it delegates — so the behavioural reference is `sindresorhus/LaunchAtLogin`'s Swift source |
| **macOS ObjC / framework FFI** | sibling **`just_font_scan`** — `libobjc.A.dylib`, `objc_autoreleasePoolPush`/`Pop`, `CFRelease`. It has already solved the autorelease-pool discipline that a naive FFI call gets wrong |
| **Pure-Dart package structure, OS-branching FFI** | sibling **`flutter_inactive_timer`** — resolves bindings as a pure function of the OS name so every arm is testable off-host. This repo converged on the same shape independently |
| **Published state** | `curl -s https://pub.dev/api/packages/just_autostart` |
| **Hidden state** | the list above, in this file |

**Never use a summarizing fetch on a reference repo.** Fetch the raw tree and the
raw file (`gh api repos/<o>/<r>/git/trees/main?recursive=1`,
`gh api …/contents/<path> --jq .content | base64 -d`) and grep the real lines. A
summarizing fetch on `launch_at_startup` reported native `windows/`/`macos/`
directories that **do not exist** (lessons #1) — the entire premise of the
project would have been wrong.

## Step 2 — boundary rule (package = mechanism, calling app = policy)

**Mechanism — this package owns it.** How a registration is *encoded, stored and
read back* on each OS: the registry value format and its quoting, the
`StartupApproved` bytes, the task definition, the plist XML, the FFI calls, and
reading the user's OS-level veto. All of it is only correct with the whole OS
state in hand.

**Policy — the calling application owns it by definition.** Whether to enable at
all; when to ask the user; the executable path (the installer's business); the
`appName` and `label` strings; the arguments; **which Windows mechanism** to use
(`Run` key vs Task Scheduler); log file locations; the toggle UI; and persisting
the user's preference. `isEnabled()` reports **OS truth**, never the app's
remembered preference — storing that is the app's job.

**The concrete expression of this boundary is that the package never infers
ambient state.** `executablePath` is required. Path discovery is the installer's.

**`enable()` overrides the user's OS-level veto.** `[product]` — matching
`launch_at_startup`, which writes the approval byte to *enabled* on every
`enable()`. The maintainer was shown the alternatives (refuse with a typed
exception; a caller-supplied `force` flag defaulting to safe) together with the
cost of each, read the reference's source, and chose to follow the established
package. Consequences accepted: no `force` parameter, no additional exception
type, and `isEnabled()` reads a veto that `enable()` will overwrite. **This is
the maintainer's call to reverse, not a derivation to re-argue.**

**What that rule is decided *on* — Windows evidence only.** The reference's
override is in its *Windows* implementation; its macOS path delegates to an API
with no force option at all. So the rule above is confirmed for one of the two
platforms and **assumed** for the other: whether `launchctl enable
gui/$UID/<label>` succeeds unprivileged is unmeasured, because launchd's disable
overrides live in root-owned state. **#9 measures it and writes the answer back
here.** If it cannot be cleared, `enable()` on macOS throws a typed exception
naming the veto — the one thing it may not do is return success while
`isEnabled()` still reads false, which is the reference's defect (lessons #2),
not its behaviour.

**But `enable()` must never silently fail.** This is *not* part of the behaviour
being followed — it is the reference's defect. `LaunchAtLogin` swallows a failed
`register()` into a log line, so the caller cannot tell success from failure and
a subsequent `isEnabled()` still reads false (lessons #2). Every failure here
surfaces as a typed `AutostartException`.

**Cross-repo rules are N/A — nothing is published.** The SDK-floor constraint,
the two-consumer signal, and the report-upstream duty all assume consumers that
cannot be seen from here. The only consumer seam is `example/`, in the same PR
and the same gate, so a drift shows up immediately. **The after-merge downstream
loop is N/A on the same ground.** All of this becomes live at the first publish.

## Step 4 — proof method per layer

| Layer | Proof |
|---|---|
| **Pure encoding / parsing** (command line, approval bytes, task XML, plist XML) | round-trip — encode then decode yields the original — plus golden values taken from what the **OS itself wrote**, not from what we think it writes |
| **Registry I/O** | write through our FFI, then read back with a **different reader** (`reg query`) against a scratch subkey under `HKEY_CURRENT_USER` |
| **plist I/O** | write through our code, then validate with **Apple's own parser** (`plutil -lint`, `plutil -p`), not only with ours |
| **Task Scheduler** | `schtasks /query` — the platform's own parser accepting the definition is the assertion |
| **Consumer round-trip** | N/A until first publish. The link mechanism when it applies: `dependency_overrides: {just_autostart: {path: ../just_autostart}}` in the consumer, then the consumer's **full** suite |

**Trap — the tautological proof.** Our writer agreeing with our reader proves
nothing about whether Windows or launchd will *accept* what we wrote. Every I/O
layer above cross-reads with an OS-native tool for exactly this reason. A test
that only round-trips through our own code is a feel test.

**Trap — CI cannot verify the thing the package is for.** A green matrix proves
"the bytes are what we intended", never "the program starts at login". Actual
login verification is manual, once per backend, and its absence from CI is a
known gap — not a covered case. Say which of the two you have.

**Trap — the example is a proof surface, and the tests are not.** The 31 tests
at the time of writing are pure functions and facade delegation; they passed
while the unsupported-platform message read *"no backend for "windows".
Supported platforms are Windows and macOS."* Running `example/` caught it
(lessons #5). Documentation and user-facing strings are read, not asserted.

## Step 5 — unconditional completeness triggers

The completeness pass runs on these **regardless** of the enumeration-risk
judgement, and these are the only paths where a second, *refuting* lens is worth
its cost. `[product]` — chosen by the maintainer.

1. **Any path that can delete another application's registration.** `disable()`,
   and the mechanism-transition cleanup that removes the other mechanism's entry.
   The `Run` key, the Task Scheduler folder and `LaunchAgents` are all **shared
   namespaces keyed by a name we construct**. A wrong name here silently destroys
   a third party's autostart and there is no undo.
2. **FFI memory and buffer-size negotiation.** The two-call `RegQueryValueExW`
   pattern, UTF-16 length arithmetic, and free ordering. A mistake is not a
   failing test — it is process corruption, or silent corruption that passes.

Everything else is gated on enumeration risk as usual.

## Step 6 — behaviour-describing surfaces

- **`CHANGELOG.md`** — pub.dev **snapshots at publish**. Never rewrite a
  published entry; open a new version.
- **`README.md`** — the landing page. It must carry the Windows console-window
  behaviour and the macOS sandbox/App Store limitation, because both change which
  mechanism a reader should pick and both are discovered painfully otherwise.
- **Public dartdoc** — ships verbatim as the API reference. It is the surface most
  likely to still describe the old behaviour, and it lies in a way tests cannot
  catch (lessons #5).
- **`example/`** — a specification. A new public API is proven by being *used*
  here, and the example must not model a practice the package documents against
  (it showed `Platform.resolvedExecutable`, which the config's own dartdoc warns
  against — lessons #6).
- **`.pubignore`** — load-bearing. A top-level `docs/` collides with pub's
  reserved `doc/` layout name and **blocks publishing entirely** (lessons #4). A
  present `.pubignore` also *replaces* `.gitignore` for archive purposes, so its
  entries must be repeated there.
- **Decision records** — `docs/adr/`, per `docs/agents/domain.md`. **Areas that
  already carry a record: none.** That empty list is what the filing step checks
  before proposing a spine, so a cluster with a home never gets a second one —
  keep it current as records land.
- **The issue tracker** is the decision trail until `docs/adr/` exists.

**What earns a record here:** two or more of theflow's promotion triggers in one
pass. Below that bar, one trigger is a decision in its issue, attached to (or
opening) a spine issue. The tracker is GitHub Issues with **native issue
dependencies** already in use, so a spine links its siblings through the
tracker's own parent/child mechanism — no project exception applies.

## Step 7 — gate matrix

Three runners, identical commands. Verified green on `41cef35`.

```
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

- **The blind spot here is per-runner, not per-member.** From #4 onward, the
  Windows runner is the *only* one that executes a registry call and the macOS
  runner is the *only* one that touches a plist. A green ubuntu job proves the
  pure logic is host-independent and **nothing else**. Never read a green matrix
  as "the backend works".
- **`dart test` does not run `example/`.** It has no separate `pubspec.yaml`, so
  `dart analyze` covers it, but nothing executes it. The one defect that unit
  tests could not catch was caught by running it by hand (lessons #5) — this gap
  is recorded, not closed.
- **Run each gate bare, never piped.** `dart test | tail -1 && commit` always
  commits: a pipeline's exit status is `tail`'s, and `tail` always succeeds.
- **Never move a threshold to turn a build green.** `--fatal-infos` and
  `--set-exit-if-changed` are the floor; raise them when the real number rises.
- **Convention:** ticket → implement → `/code-review` → commit referencing the
  issue (`Closes #n`) → fast-forward merge to `main` → push → confirm CI green.
  No PR flow; this is a solo repo and a PR per ticket was weighed and declined.
- **Release:** `dart pub publish --dry-run` must be **0 warnings**. Currently
  blocked on a missing `LICENSE`. `dart pub publish` is irreversible — **the
  agent does not run it; the user does.**

## War-story index

Per-incident evidence lives in [`lessons.md`](lessons.md), indexed by step.
