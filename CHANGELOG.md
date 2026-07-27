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
- macOS is not implemented yet and is served by the unsupported backend.
