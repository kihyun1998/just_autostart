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
- macOS is not implemented yet and is served by the unsupported backend.
