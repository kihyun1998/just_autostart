## 0.1.0

Unreleased.

- Establishes the cross-platform `Autostart` surface, platform dispatch, and the
  shared exception hierarchy.
- Windows autostart through the registry `Run` key, on hand-written `dart:ffi`
  bindings to `advapi32` — no dependency on `package:win32`. The executable path
  is quoted unconditionally, so an install directory containing a space works.
- `disable()` removes only registrations this package wrote; a value it does not
  recognise is left in place, because the `Run` key is a namespace shared with
  every other application on the machine.
- `isEnabled()` honours the user's Task Manager "Startup apps" toggle, which
  Windows stores in a separate key from the registration itself. `enable()`
  clears that veto.
- Windows autostart through **Task Scheduler**, chosen with
  `WindowsAutostartOptions`. It is the only unelevated mechanism that can start
  a `dart compile exe` program with **no console window**, and the only one that
  can delay the start. The `Run` key remains the default.
- A combination the chosen mechanism cannot honour — hiding the window, or a
  startup delay, asked of the `Run` key — throws `ArgumentError` instead of
  being quietly dropped.
- On Task Scheduler, `isEnabled()` accounts for **both** of the switches the
  Task Scheduler UI offers: disabling the task, and disabling its trigger. A
  task with either switched off is reported as not enabled, and its
  registration is left untouched.
- Scheduled tasks are registered with the settings Windows would otherwise
  default to wrongly for a login daemon: no battery restrictions, and no
  three-day execution time limit.
- Switching between the two Windows mechanisms no longer leaves the program
  launching twice: `enable()` removes any registration the other mechanism
  holds, and `disable()` clears both. Cleanup removes only registrations naming
  the configured executable, so a third party's autostart under a colliding
  name is left alone — as is one this package wrote at an earlier install path,
  which it cannot tell apart from a stranger's.
- `MechanismCleanupException` reports the case where the new registration
  succeeded but the old one could not be removed. It is a separate type because
  autostart *is* on, which is not what "enable failed" means.
- A scheduled task is recognised as this package's own only when its principal
  is the current user. The Task Scheduler tree is machine-wide where the `Run`
  key is per-user, so two users of one installation would otherwise be
  indistinguishable by path alone.
- macOS autostart through a **launchd user agent** — a property list in the
  user's `LaunchAgents` directory, written with `dart:io`. No FFI, no
  dependency, and no `.app` bundle: `SMAppService` cannot register a bare
  `dart compile exe` binary, so a LaunchAgent is the mechanism. Writing the file
  is enough to start the program at the next login; launchd scans the directory
  then.
- `isEnabled()` on macOS reports what will *actually* launch, not merely that a
  file exists: it reads the executable and arguments, `RunAtLoad`, and the
  in-plist `Disabled` key — three stores inside the file, any of which can leave
  a present plist inert — **and** the user's System Settings Login-Items veto,
  the fourth store, which lives outside the plist in launchd's disable overrides
  and is read through `launchctl`.
- `enable()` on macOS **clears that veto**, so an app that calls `enable()` after
  the user switched the agent off in System Settings turns it back on rather than
  returning a success that `isEnabled()` would immediately contradict. Clearing
  the override was measured to work for an unprivileged user; where it genuinely
  cannot (the veto stands and will not clear), `enable()` throws rather than
  reporting a false success. A `launchctl` that cannot be read at all degrades to
  "no veto known", the same for both calls, so they never disagree.
- `disable()` on macOS removes a plist only when its internal `Label` is this
  application's — launchd identifies a job by that label, not by the file name,
  so a third party's agent that merely shares the file name is left untouched.
  The check is made **twice**, the second time immediately before the file is
  removed: a `launchctl` call runs between them, and the deletion acts on the
  path rather than on the bytes the first check read. Measured on macOS 14.5,
  the gap between the last look and the removal falls from ~3,445 µs to 49 µs.
  It is also now *bounded*: `disable()` no longer reads anything that can block
  indefinitely, so a FIFO planted at the plist path is left alone instead of
  hanging the call.
- `enable()` on macOS writes the agent **into** its own slot rather than through
  whatever occupies it. `~/Library/LaunchAgents/<label>.plist` may already be a
  symlink — a plist kept in a dotfiles repo, say — and writing directly followed
  it, putting this package's bytes outside the one directory it manages: a
  symlink's target had its content replaced, and a *dangling* symlink had its
  target created. The plist is now written beside the slot and renamed over it,
  which by `rename(2)` replaces the link itself and leaves its target untouched.
  A caller who deliberately symlinked that path will find it replaced by a real
  file the first time `enable()` runs.
- The same change fixes a false success: with a FIFO at the plist path,
  `enable()` reported success while `isEnabled()` stayed false for ever, because
  the bytes went into the pipe rather than to disk. A registration reported live
  that can never launch is the one outcome this package exists not to produce.
- Writing through a temporary file also means the agent is never briefly visible
  carrying the permissions launchd silently refuses, and a crash mid-write can no
  longer leave a truncated plist that `disable()` would refuse to clean up.
- `disable()` on macOS no longer throws when the plist disappears underneath it,
  so two concurrent calls no longer make the loser fail. A plist it cannot
  *read* — as opposed to one that is absent or foreign — is still reported as a
  typed `AutostartOsException` rather than silently treated as somebody else's.
- `MacosAutostartOptions` configures **how** launchd runs the agent: restart on
  exit (`keepAlive`), standard output and error paths, a working directory, and
  environment variables. A login agent inherits none of a login shell's
  environment and has no terminal attached, so a daemon that behaves differently
  at login than by hand — or that fails invisibly — usually needs these. Each is
  written to the plist **only when supplied**, so a caller who configures
  nothing gets the same minimal agent as before and launchd applies its own
  defaults.
- `activateImmediately` starts the agent in the **current** session on
  `enable()`, for a user who has just switched a toggle on and expects it to
  work now. `disable()` removes the agent from the session before deleting the
  plist **whether or not this option is set**: the option describes the backend
  instance rather than the registration, so gating the removal on it let an
  application that enabled with it, and disabled without it, delete the file
  while the job stayed loaded — with nothing able to unload it by name until the
  next login.
  A failure to start it now does **not** throw: the registration is written and
  the agent starts at the next login regardless. `isRunningNow()` reports
  whether it is actually running, read from launchd rather than remembered —
  the exit codes cannot be trusted for this, because `launchctl` fails both when
  bootstrapping an already-loaded agent and when booting out one that is not
  loaded, which are the ordinary repeat paths.
- The written agent is never left writable by group or other. launchd refuses
  such a job definition **silently**, and `File.writeAsStringSync` inherits the
  process umask — so under `umask 0` or `umask 002` the registration looked
  successful, reported as enabled, and could never launch. `enable()` now clears
  those two bits, keeping a stricter mode as it found it, and `isEnabled()`
  treats a group- or other-writable agent as not enabled.
- `ExecutablePermissionException` reports an executable that exists but has no
  execute bit — it would pass an existence check and then fail to launch at
  login. `MalformedRegistrationException` reports a plist too corrupt to read
  back.
