# ADR-0003 — What this package's `Future`s promise, and how a duration may be stated

**Status:** Accepted — 2026-07-29
**Supersedes:** nothing
**Promoted from:** issue #17, per theflow's promotion rule (three triggers: that
issue's stated premise measured false before work started, in two separate ways;
the reference implementation cannot arbitrate, because it reaches the same
signature for a reason that does not apply here; and two artifacts inside this
repo require opposite things — ADR-0002's R3 forbids unbounded I/O inside the
deletion window while #18 records that Windows performs exactly that, inside
exactly that window).

## Why this is a record and not an issue

An issue holds one decision. This holds a **rule that spans decisions**: what
every operation on every backend promises by returning a `Future`, and what any
doc comment, issue or changelog entry in this repo is allowed to claim about how
long one takes.

Both halves have already been decided ad hoc and inconsistently. #14 recorded the
synchronous-under-a-`Future` problem for macOS and deliberately left it open.
#17 re-derived it for Windows against a table of durations. #16 and #22 each
narrowed a window and reasoned separately about what may sit inside it. #18 is
open and is about a call with no ceiling. Every one of those is the same two
questions in a different vocabulary, and the next operation this package grows —
a Startup-folder mechanism, a Linux backend, a bounded lookup — would arrive as a
fresh decision and reinterpret the last.

It is also **expensive knowledge**, and the expense was mostly spent discovering
that the obvious numbers are not usable. See "The governing facts".

## Context

Every method on every backend returns a `Future`. **None of them yield.** On
Windows the work is `dart:ffi` and COM, synchronous by nature; on macOS it is
`Process.runSync` and synchronous file I/O. `await autostart.isEnabled()`
occupies the calling isolate for the whole operation.

The package's own documentation points callers at `isEnabled()` to render a
settings toggle, so the question is not academic. But the package's stated
identity (`CLAUDE.md`) is *"a Dart command-line program or daemon"*, and those
two consumers want opposite things from the same method.

## The governing facts

Measured on Windows 11 Pro build 26200, Dart 3.11.5, `dart compile exe`, one
operation per fresh process against scratch locations, medians of 9–11 runs.

**F1 — the cheap mechanism is genuinely cheap, and an isolate hop would double
it.** `runKey.isEnabled()` is **41 µs** on its second call in a process (range
31–70) and **239 µs** cold. The whole per-isolate re-pay of the FFI bindings —
advapi32, the `Reg*` lookups, every trampoline — measured by running the same
operation in a spawned isolate whose parent had already run it, is **+30–70 µs**.
On a ~40 µs operation that is not an overhead, it is a second copy.

**F2 — the expensive mechanism's cost cannot be stated as a single number on
this machine.** `taskScheduler.isEnabled()`, same fixture, same binary, one
operation per fresh process: **5,030–18,597 µs**. #16 recorded per-block spreads
of 9.6–31.8 ms independently. The cost is RPC round trips to the Task Scheduler
service (#19), which takes machine load directly.

**F3 — and the fixture moves it threefold, which no previous table stated.**
`taskScheduler.isEnabled()` with the task registered: **15.0 ms**. With the
folder absent: **5.5 ms**. #16 measured the same distinction on `disable()` at
24.2 ms against 2.70 ms. A duration quoted without its fixture is not a fact
about the operation.

**F4 — the per-isolate re-pay does *not* dominate the expensive path, and the
reason it can be asserted is that it is below the noise.** The same
spawned-versus-parent comparison on `taskScheduler.isEnabled()` returned values
from −615 µs to +849 µs across nine runs, several of them negative. #17's open
question 2 asked whether a fresh isolate's re-initialisation "may dominate the
operation being moved". On Windows it is smaller than that operation's own
run-to-run variance. `DynamicLibrary.open` documents why: calling it again with
the same path, *"even across different isolates, only loads the library into the
DartVM process once"*.

**F5 — the same question has a different answer on macOS, and there it is not
falsified.** `SystemLaunchctl`'s `_cachedGuiDomain` is a top-level mutable, so it
is **per isolate**. Any isolate hop gets a fresh one and re-pays the `id -u`
spawn that #14 existed to remove — measured there at 3,153 µs, and at 1,533 µs
cold AOT in #22, against a post-#14 `isEnabled()` of 4,102 µs. A third to a half
of the thing being moved. *Validity condition:* read from the code and from
#14's and #22's recorded measurements; **not re-measured in a spawned isolate**,
because that needs a macOS machine. Recorded as the reason the hop is not taken,
not as a number to build on.

**F6 — no duration in this package is a ceiling, on either platform.** This is
the fact that reframes the rest, and #17's own table gets it backwards by
presenting Windows as the bounded platform.

- **Windows.** `_runsAsCurrentUser` sits inside `deleteTaskIf`'s window and
  reaches `isCurrentUser` → `LookupAccountNameW`, which on a domain-joined
  machine goes to a domain controller over the network with **no timeout** (#18).
  ADR-0002's R3 — *"no I/O whose duration another party controls"* — is
  therefore violated on Windows today, inside the window #16 narrowed.
- **macOS.** `Process.runSync` takes no timeout parameter (`launchctl.dart`), and
  `readAsStringSync` on a FIFO blocks until a writer appears (#22). A
  `Future.timeout` around synchronous work cannot fire, because the isolate never
  returns to the event loop that would deliver it (`lessons.md` #29).

**F7 — the reference reaches this package's signature for a reason that does not
apply here.** `launch_at_startup` 0.5.1 declares `Future<bool> isEnabled()` and
its Windows implementation is synchronous `win32_registry` inside an `async`
body, with no `await` — identical to this package. But its one interface also
serves Linux and macOS implementations that shell out with the **asynchronous**
`Process.run`. Its `Future` is load-bearing; ours is not. Meanwhile
`package:win32` 5.15.0 has **zero** `Future` across 287 library files, COM
included, and Effective Dart says *"DON'T use `async` when it has no useful
effect."* The reference cannot arbitrate: it agrees with us, for a reason we do
not have.

## Decision

**Five rules. Together they resolve every combination rather than listing the
ones already met.**

### R1 — The signatures stay `Future`, and the `Future` is reserved capacity, not a claim

Every backend operation keeps its `Future` return type. It does **not** assert
that the operation yields, and today none does.

It is kept because removing it forecloses the only fix that can ever make these
calls *bounded*: `Process.start`/`Process.run` with a timeout on macOS, which
#14 deferred and #17's own second comment names, and whatever bounds
`LookupAccountNameW` on Windows under #18. A synchronous signature makes that a
breaking change on a published surface. **Nothing is published yet** — `#11` is
open — so this is the last moment the choice is free, which is why it is recorded
as a choice rather than left to inertia.

This is the answer to F7: the `Future` is not decoration justified by the
reference, it is a reserved bound justified by two open tickets.

### R2 — Every operation documents that it runs synchronously and does not yield

The seam contract (`AutostartBackend`) and the public facade (`Autostart`) say so
in their dartdoc, in the same words on both platforms, so `isEnabled()` cannot
mean one thing on Windows and another on macOS. This is what closes #14's open
note.

### R3 — No duration recorded anywhere in this repo is a ceiling unless this record says it is bounded, and today none is

A duration may be written into a doc comment, an issue, a changelog or an ADR
**only** with:

- the **fixture** it was taken against (registered / absent — F3 moves it 3×),
- the **artefact** (`dart compile exe`, not `dart run` — `lessons.md` #29),
- the **shape** (one operation per fresh process, or a warm steady state — F1
  differs 6× between them),
- and, where the spread swamps the median as in F2, **a range rather than a
  point**.

A sentence of the form "this blocks for X" is forbidden without the words that
say X is a median and not a maximum. F6 is why: on both platforms the tail is
unbounded, and the failure mode this package exists to prevent is a confident
claim that is false at the edge.

### R4 — The isolate hop belongs to the calling application, and the package makes it possible rather than making it

A caller who needs the calling isolate free writes
`await Isolate.run(() => autostart.isEnabled())`. The package's obligation is to
make that work and to say so:

- every object reachable from `Autostart` stays **sendable**. The FFI handles
  stay per-isolate lazy top-level `final`s rather than becoming fields, which is
  what keeps this true — measured, the unsendable set that this package could
  realistically acquire is `DynamicLibrary` and `ReceivePort` (plus
  `Finalizable`, `UserTag` and anything marked
  `@pragma('vm:isolate-unsendable')`). **`File`, `Directory` and `Pointer` are
  all sendable**, which is worth writing down because it is the intuitive list
  and it is wrong: an earlier draft of this record named three of them as
  hazards and a probe refuted it;
- every `AutostartException` subclass stays **sendable**, so a failure crosses
  the boundary as its type and not as a `RemoteError` string, which would be
  `lessons.md` #2's defect by a new route;
- both are pinned by a test, because neither is expressible as a type
  (`lessons.md` #14's shape).

What the caller is buying is documented honestly, including the costs: the
calling isolate's stack frames are absent from any thrown trace, a
`Autostart.withBackend` fake does not observe its own mutations across the hop,
and on macOS the hop re-pays F5.

### R5 — If the package ever does take a hop, it goes below the `AutostartBackend` seam and wraps a whole operation

Not chosen now, but pre-decided so the next ticket does not re-derive it:

- **Below the seam**, inside a mechanism backend, because at or above it the
  copied collaborators include a caller-supplied fake whose mutations become
  invisible (`Autostart.withBackend` is a documented public feature).
- **Wrapping a whole synchronous operation**, never threading `Future` through
  one. #17's first comment establishes why: an `await` between an ownership
  check and a deletion hands the interval's length to the caller's event loop,
  which is strictly worse than what ADR-0002 R3 permits. `withCom` already
  refuses a `Future` body at runtime for the apartment's sake.
- **And the safety comes from the synchronous block, not from the isolate.**
  `Isolate.run`'s computation runs in `_RemoteRunner._run`'s synchronous prefix,
  so a synchronous body is one uninterrupted stretch; but `Isolate.run` accepts
  an `async` closure, and Dart isolates are multiplexed onto a shared thread
  pool. Writing "an isolate makes it safe" would be `lessons.md` #14 recurring
  one abstraction level up.

## Rejected alternatives

**Make the signatures synchronous.** The strongest technical argument in the
corpus — F7's ecosystem half, and it removes a promise the implementation does
not keep. Rejected on R1: it permanently forecloses the bounded call on a
published surface, and #18 and the macOS half are both open tickets that may
need it. Also collides with F6: its premise is writing "this blocks for X", which
R3 forbids in the unqualified form.

**Synchronous primary with `Async` twins** (`isEnabled()` / `isEnabledAsync()`),
the shape `objectbox` ships and `isar` inverted to in v4. Genuinely clears every
constraint. Rejected because it doubles a three-method public surface to serve a
hop the caller can write in one line (R4), and because the two conventions
available — `dart:io`'s async-unsuffixed and the FFI family's sync-unsuffixed —
disagree about which name gets the cheap path, so the choice would itself need
this record. Reachable later without a breaking change; the reverse is not true.

**`Isolate.run` inside the Task Scheduler backend only.** The shape #17 was
written around. Rejected on F1 asymmetry being the wrong asymmetry: it leaves the
`Run` key caller paying a full Task Scheduler COM session on two of three public
operations anyway (`WindowsAutostartBackend.enable()` cleans up the other
mechanism), so it does not deliver a cheap path; and it is Windows-only by
construction, which is the drift #14's note exists to prevent.

**`Isolate.run` everywhere.** Rejected on F5 — it silently reverts #14 on macOS
— plus the R4 costs paid by every caller including those who never wanted it.

**A resident worker isolate.** The only isolate shape that pays the spawn and the
binding re-resolution once, and the only one that would keep macOS's
`_cachedGuiDomain` warm. Rejected on the mechanism, not on omission:
`CoUninitialize` *"unloads all DLLs loaded by the thread … and forces all RPC
connections on the thread to close"*, so a worker does not amortise the 1.35 ms
`Connect` unless it holds a COM apartment open across event-loop turns, which
`withCom`'s own reasoning forbids. A live isolate also keeps the process alive,
and the target is a CLI that exits; a three-method API has nowhere to put a
shutdown.

**An `offloadToIsolate` option on `WindowsAutostartOptions`.** The precedent is
real (`hideWindow: bool?`, `lessons.md` #20). Rejected because the option would
be a per-platform knob for something the caller can already express portably at
the call site, and because it would have to be honoured on macOS where F5 makes
it a regression.

**macOS goes genuinely asynchronous via `Process.run`.** Not rejected — **not
decided here.** It is the only route to a real bound (F6) and it is orthogonal to
R1, since the signature stays `Future` either way. It carries its own constraint:
`MacosAutostartBackend.disable()` re-establishes its ownership guard after
`bootout` and before `deleteSync`, and nothing between those two may become
asynchronous. Tracked as a conformance item under this record.

## Consequences

*(Currently-true statements. Flip them when the decision flips.)*

- `Autostart.enable()`, `disable()` and `isEnabled()` return a `Future` that is
  already complete when the caller receives it. `await`ing one never yields to
  the event loop.
- A caller on a UI isolate that cannot afford the block wraps the call in
  `Isolate.run` itself, and this is documented rather than provided.
- Every object reachable from `Autostart`, and every `AutostartException`
  subclass, is sendable. `test/isolate_contract_test.dart` asserts it, and the
  assertion is credited: planting an unsendable field turns exactly the
  sendability group red and leaves the rest green.
- **R4's insulation also rests on no FFI binding being `isLeaf`.** Verified: zero
  occurrences in `lib/`. `DynamicLibrary`'s own documentation is the reason it
  matters — *"if one isolate in a group is trying to perform a GC and a second
  isolate is blocked in a leaf call, then the first isolate will have to pause
  and wait"*. So a caller's `Isolate.run` genuinely frees their isolate today,
  and would stop doing so if a later performance change marked a binding
  `isLeaf: true` — after this record had already stated the insulation as
  currently true. It is a Consequence rather than a rule because nothing here
  needs `isLeaf` yet.
- The way that guarantee breaks is by caching a **`DynamicLibrary` as a field**
  — the one unsendable type this package handles at all. It is currently a
  per-isolate lazy top-level `final` in `com.dart`, `registry.dart` and
  `current_user.dart`, and a future "resolve the bindings once" refactor is
  exactly the change that would move it into a field and revoke R4 silently.
- No doc comment in this package states a duration as a maximum. Where one
  states a median it names its fixture, its artefact and its shape.
- The Windows deletion window contains an unbounded network call (#18) and this
  record does not close it. ADR-0002's R3 is violated there today; #18 is the
  ticket that decides what to do about it, and this record is why it may not be
  closed by documenting a median.
- macOS keeps `Process.runSync`, so its calls have no ceiling either. R2's
  wording is the same on both platforms because the *promise* is the same; the
  bound is absent on both.
- `#19` may not publish a point value for `taskScheduler.isEnabled()`. F2 and F3
  are the constraint it inherits.

## How to re-measure

The probes were disposable and were deleted; the method is what is kept.

1. **AOT, one operation per fresh process.** A warm loop measures a steady state
   a single-shot CLI never reaches, and `dart run` is not what consumers ship —
   `lessons.md` #29 records both errors in one benchmark.
2. **State the fixture in the same breath as the number** (F3).
3. **For the per-isolate re-pay, put both spans in one process, back to back:**
   the parent's *second* call against the same operation timed *inside* a
   spawned isolate. Timing the parent's first call measures the process-wide DLL
   load instead, and timing `withCom` alone measures `ole32` and two bindings
   while the operation being moved also touches `oleaut32`, advapi32 and every
   trampoline. Both of those errors were made and caught here.
4. **Check for a null control before differencing against an older table.** The
   `Run` key path has not changed since before #15; if its figure does not
   reproduce, the harness moved and no other row from that run means anything.
   That control is what showed #17's table is not differenceable.
5. **Do not measure while background agents are running.** A completeness pass
   inflated `taskScheduler.isEnabled()` by roughly 2× here, and produced
   `readTask` > `isEnabled()` — an impossible ordering, since the second contains
   the first. That impossibility is a cheaper load detector than measuring load.
