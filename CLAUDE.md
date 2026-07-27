# CLAUDE.md

## Working discipline — theflow

Substantive changes (a feature slice, a bug fix, a refactor touching the public
surface) follow the **`theflow`** skill — run `/theflow` at the start. This
repo's bindings (module map, hidden-state list, reference routing, boundary rule,
proof methods, sacred paths, surfaces, gate matrix) live in
**`docs/agents/theflow.md`**; the per-incident evidence in
**`docs/agents/lessons.md`**. Read both before starting, and add new war-stories
to lessons with the step number they give teeth to.

## Identity & invariants (the boundary)

`just_autostart` launches a **Dart command-line program or daemon at login** on
**Windows and macOS**. It is pure Dart: no Flutter dependency, no native sources
to compile, and no step where a consumer opens Xcode or edits a Swift file.

Its identity is a **boundary** — it stays correct by *not* absorbing the concerns
of the application that calls it. theflow Step 2 grounds its judgement here.

- **The core owns the mechanism:** how a registration is encoded, stored, and
  read back on each OS — the registry value format and its quoting, the
  `StartupApproved` bytes, the scheduled-task definition, the LaunchAgent plist,
  the FFI calls, and reading the user's OS-level veto. All of it is only correct
  with the whole OS state in hand.
- **The calling application owns the policy:** whether to enable at all, when to
  ask the user, the executable path, the `appName` and `label` strings, the
  arguments, **which Windows mechanism** to use (`Run` key vs Task Scheduler),
  log locations, the toggle UI, and persisting the user's preference. That is
  the boundary, not a workaround.
- **Contract, not a defect — `executablePath` is required and never inferred.**
  Under `dart pub global activate`, `Platform.resolvedExecutable` points at the
  Dart runtime rather than the caller's tool, so inferring it would silently
  register the wrong binary. Path discovery is the installer's job.
- **Contract, not a defect — `isEnabled()` reports OS truth**, never the app's
  remembered preference. An app that wants to remember what the user chose
  stores that itself.
- **`enable()` overrides the user's OS-level veto**, matching
  `launch_at_startup`. This is a **product decision** recorded in
  `docs/agents/theflow.md` — the maintainer's to reverse, not a derivation to
  re-argue.
- **But nothing fails silently.** Every failure surfaces as a typed
  `AutostartException`. The reference implementation swallows a failed macOS
  registration into a log line, which is the defect this package does not copy
  (`lessons.md` #2).
- **Recurring hazard — existence is not enablement.** Every surface this package
  writes to has a *second* store holding the user's veto, and it is never the
  store you just wrote: the `Run` key has `StartupApproved\Run`, a scheduled task
  has its own enabled flag, a LaunchAgent plist has launchd's disable overrides.
  Every read path reads both; every write path maintains both.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `kihyun1998/just_autostart`, driven by the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary; each label string equals its canonical name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` plus `docs/adr/` at the repo root. Neither exists
yet; `/domain-modeling` creates them lazily. See `docs/agents/domain.md`.
