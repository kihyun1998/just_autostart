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
- macOS is not implemented yet and is served by the unsupported backend.
