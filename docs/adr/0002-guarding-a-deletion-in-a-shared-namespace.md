# ADR-0002 — Guarding a deletion in a shared namespace

**Status:** Accepted — 2026-07-29
**Amended:** 2026-07-29 — #23 settled the write side; W1 and W2 added under
"What the rules do not decide", which previously declared it out of scope.
**Supersedes:** nothing
**Promoted from:** issue #22, per theflow's promotion rule (three triggers: that
issue's stated premise measured false before work started; the reference
implementation cannot arbitrate because it never deletes a registration at all;
and the same ownership-guard-vs-deletion pair had already been decided
separately for the `Run` key, Task Scheduler, and `LaunchAgents`).

## Why this is a record and not an issue

An issue holds one decision. This holds a **rule that spans decisions**: every
mechanism this package writes to is a namespace shared with other applications,
keyed by a name the *caller* supplies, and every one of them therefore needs an
answer to "may I remove this?". That question has now been answered three times,
in three tickets, in three different vocabularies — #5/#7 for the `Run` key,
#15/#16 for Task Scheduler, #8/#22 for `LaunchAgents` — and each answer was
reached by re-reasoning from scratch rather than by applying a rule.

The combinations are not exhausted. A Startup-folder shortcut mechanism, a
system `LaunchDaemons` variant, or a second Windows task folder would each
arrive as a fresh decision, and each would re-interpret the last. This record
exists so the fourth mechanism resolves *by construction*.

It is also expensive knowledge. The `Run` key's canonical-quoting rule, Task
Scheduler's SID-resolves-to-a-name asymmetry, and launchd's label-not-filename
identity were each found by a measurement that contradicted the obvious reading,
and two of them by an adversarial pass after the ticket looked finished.

## Context — what makes this a class rather than three coincidences

| mechanism | the namespace | keyed by | can a stranger legally occupy our key? |
| --- | --- | --- | --- |
| registry `Run` key | `HKCU\...\Run` | value name = `appName` | yes |
| Task Scheduler | a folder under the task tree | task name = `appName` | yes |
| launchd user agent | `~/Library/LaunchAgents` | file name = `<label>.plist` | yes |

In all three the key is assembled from caller-supplied text, a third party may
have got there first, and **the removal has no undo**. `docs/agents/theflow.md`
already names this as an unconditional completeness trigger. What it did not
carry was the rule.

## The governing facts

Four, each measured, and together they generate every decision below.

1. **A name is not an identity.** Every mechanism hands back something richer
   than the key, and the richer thing is what says whose registration this is:
   the `Run` value's canonical command line, a task's principal and action path,
   a plist's internal `Label`. launchd is the sharpest case — it identifies a job
   by the `Label` *inside* the file, so a stranger's plist can legally sit at
   `<our-label>.plist` (#8).
2. **The identity crosses the OS boundary in both directions, and may not come
   back in the form it went out.** `IPrincipal::put_UserId` takes a SID and
   `get_UserId` returns an account name (#21, `lessons.md`), so a guard that
   compares what it wrote against what it reads must normalise. Reading the XML
   the OS exports for humans does not establish this.
3. **No mechanism offers an identity-keyed delete.** `ITaskFolder` has no delete
   taking the `IRegisteredTask` you inspected; `IRegisteredTask` has no `Delete`;
   `File.deleteSync` unlinks a *path*, and Dart exposes no way to unlink an
   inode (`FileStat` carries no inode, `RandomAccessFile` cannot unlink). So
   check-then-act is the only shape available, on every mechanism, and a window
   always remains.
4. **The window's danger is its ceiling, not its median.** #22 measured
   `File.existsSync()` returning `true` for a FIFO whose read then blocks for
   ever, and `Process.runSync` has no timeout. A window containing either is
   unbounded, and no median describes it.

## Decision

**Five rules. A mechanism conforms or it does not ship.**

**R1 — Decide ownership from the identity, never from the key.** A read that
returns only "something is registered under this name" may not authorise a
removal. This is why `taskExists` was deleted rather than kept as a convenience:
a fast way to ask the weaker question is a trap on a class that can also delete
someone else's registration.

**R2 — Normalise both sides of the comparison through the same API the guard
uses.** Not through whatever the OS exports for display. Fact 2.

**R3 — The last look and the act are separated by no subprocess, no blocking
call, and no I/O whose duration another party controls.** Between them may sit
only bounded, local computation. This is the rule #22 added and it is the one
with teeth: `deleteTaskIf` satisfies it by holding one COM session across both;
`MacosAutostartBackend.disable()` satisfies it by re-establishing the guard
after its `launchctl` call rather than before.

**R4 — Refuse what cannot be a registration before opening it.** A directory, a
FIFO, a device, a name that resolves to nothing. This is what makes R3's "no
blocking call" achievable rather than aspirational; without it the guard's own
read is the unbounded call.

**R5 — Unreadable is not unowned.** A registration this package cannot read is
reported as a typed failure, never silently treated as a stranger's and left in
place. The failure mode this forbids is the one `CLAUDE.md` names and
`lessons.md` #2 records in the reference implementation: an operation that
reports success while the registration is still live. *Absent*, by contrast, is
success — removing what is not there is the idempotent case, including when it
became absent mid-operation.

### What the rules do **not** decide

They govern removal. They say nothing about whether `enable()` may override a
user's veto — that is a separate `[product]` decision recorded in
`docs/agents/theflow.md`.

**The write side has since been settled by #23, and its answer is recorded here
because two of the rules above would otherwise be misread onto it.**

**W1 — `enable()` claims its slot without an ownership guard, and that is
deliberate.** All three mechanisms overwrite whatever occupies their key:
`windows_run_key_backend.dart:62-64` writes unconditionally, Task Scheduler
registers with `TASK_CREATE_OR_UPDATE` (`task_scheduler.dart:297`, `:1324`), and
the macOS backend replaces its plist. R1 is **not** violated, because R1 governs
*removal* — a path whose whole purpose is destruction — while `enable()`'s
purpose is to make this application's registration exist at a key the **caller
chose**. `[product]`: the family agrees, and this is recorded as a decision
rather than left as the omission it was. Its cost is real and stated: a caller
who picks a label another application already uses destroys that registration,
and no guard here would tell them apart from a stale copy of their own.

Do **not** cite `windows_autostart_backend.dart:61-69` either way. That *is* a
guarded deletion on an enable path, but it removes the **other mechanism's**
registration at a key the caller never asked to write, and it reuses the
ordinary `disable()` guard to do it. Different operation, precedent for neither
side.

**W2 — writing goes through a same-directory temp and `rename(2)`, and this is
not the rename rejected below.** The rejected alternative moves a registration
*away* to a private name before verifying it, on the **removal** path, and is
refused for two reasons: it can clobber a file that arrived meanwhile, and a
crash strands a third party's plist under a name launchd will not load. The
write-path rename shares neither — the source is a name only this process knows,
and a crash leaves the previous registration intact. Measured (#23):
`File.deleteSync` resolves through symlinks and *fails* on a dangling symlink
(errno 2), a symlink loop (errno 2) and a symlink to a directory (errno 21),
leaving all three in place — so "remove the slot, then write" cannot be
expressed in Dart and silently preserves the defect it appears to fix.

The general form, and the reason this belongs in the record: **on both sides,
the safe primitive is the one that does not follow the final path component.**
`unlink(2)` for removal, `rename(2)` for writing. Anything that resolves the
path — `existsSync`, `File.deleteSync`, `writeAsStringSync`, `chmod` — acts on
whatever the name points at, which on a shared namespace is not necessarily
ours.

## Evidence — the decisions this derives

The test of a record is that it *derives* what was already decided rather than
listing it. Each row below was reached independently, before the rule existed.

| already decided | derived from |
| --- | --- |
| `Run` key `disable()` matches the canonical command line, not the value name | R1 |
| A registration at an earlier install path is left alone — indistinguishable from a stranger's | R1 |
| A scheduled task is ours only when its principal is the current user | R1 |
| `isCurrentUser` resolves names *and* SIDs to a SID before comparing (#21) | R2 |
| `taskExists` removed rather than kept (`lessons.md` #27) | R1 |
| `deleteTaskIf` holds one COM session across read and delete (#16) | R3 |
| `deleteTaskIf`'s predicate is documented as forbidden to block (#16) | R3 |
| `disable()` re-checks the plist after `bootout` (#22) | R3 |
| The macOS reader refuses a non-regular file (#22) | R4 |
| A foreign `Label` and an unparseable plist are left in place, not raised (#8) | R1 |
| An unreadable plist raises `AutostartOsException` (#22) | R5 |
| ENOENT on read and on delete is silent (#22) | R5 |

**And one it contradicts, adjudicated rather than quietly flipped.** `enable()`
reads the executable with `existsSync` then `statSync`
(`macos_autostart_backend.dart:93-99`) and `_isWorldWritable` stats without
guarding (`:181`). Under R4 those would check
the entity type too. They are **not** in violation: R4 governs paths on the
*removal* class, and none of these can delete anything — the worst outcome is a
mislabelled exception on a path that writes. Recorded so the next reader sees it
was examined, not missed.

## Rejected alternatives

**Make the removal atomic.** The textbook fix is to open the registration,
verify from the handle, and remove *that* object — `renameatx_np` with
`RENAME_SWAP` on macOS, or an identity-keyed delete on Windows. Every route is a
syscall or COM call Dart does not expose. On macOS it would mean FFI in a
backend that deliberately has none (`CLAUDE.md`), and on Windows the interfaces
simply do not offer it (fact 3). Rejected as unavailable, not as undesirable —
if a future Dart exposes it, R3 becomes obsolete rather than merely satisfied.

**Rename-to-a-private-name before verifying, so the irreversible step becomes
reversible.** Considered in #22 and rejected by the maintainer. `rename(2)`
silently unlinks an existing destination, so the put-it-back path can clobber a
file that arrived meanwhile; and a process that dies mid-sequence strands a
third party's registration under a name nothing will load. It converts a rare
irreversible harm into a rarer but still irreversible one, plus a new failure
mode. `[product]` — the maintainer's to revisit.

**Compare a timestamp or a version instead of the content.** `FileStat.modified`
is settable by any unprivileged writer. `changed` (ctime) is not, which makes it
tempting, but it is a second heuristic across the same open gap rather than a
closing of it, and it adds a false-refusal mode. No mechanism here exposes a
version or generation counter.

**Accept the window as inherent and document it.** This is what #16 did for its
2,400 µs residual, and it was right *there* — both ownership terms hang off
`get_Definition`, so the cost cannot be dropped. It is wrong as a general rule,
because #22 found a window that was not merely wide but unbounded. R3 draws the
line where it can actually be drawn: not "make the window small" but "keep
specific things out of it".

## Consequences

- A new mechanism does not get a fresh ownership debate. It gets five rules and
  a conformance item.
- **The residual is stated, not implied.** Task Scheduler ~2,400 µs; macOS
  49 µs. Both are check-then-act windows that remain open, and R3 bounds what
  can be inside them rather than closing them.
- R3 is the rule most easily lost to a later "simplification", because the code
  it forbids looks like an optimisation — #22 mutation-tested exactly that
  (scoping the second guard to `activateImmediately`) and the suite killed it.
  A mechanism conforming to R3 needs a test that dies when the guard moves.
- **`[product]` — the residual windows are accepted.** The maintainer was shown
  the measurements, the rename alternative and its two failure modes, and chose
  the guard-based shape. Theirs to reverse.

## How to re-measure

The window figures in this record are AOT, one operation per fresh process. A
warm loop under `dart run` gave answers wrong in three directions at once
(`lessons.md` #29) — the first parse was 7× cheaper than the real one, JIT
overstated the parser by 25×, and a subprocess inside the window went uncounted
entirely. Rebuild with `dart compile exe`, run one operation per process, and
name the two events any figure spans (`lessons.md` #28).
