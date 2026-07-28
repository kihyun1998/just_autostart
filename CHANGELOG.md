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
- `ExecutablePermissionException` reports an executable that exists but has no
  execute bit — it would pass an existence check and then fail to launch at
  login. `MalformedRegistrationException` reports a plist too corrupt to read
  back.
