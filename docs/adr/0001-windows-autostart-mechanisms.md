# ADR-0001 — Windows autostart mechanisms, and how the console window is hidden

**Status:** Accepted — 2026-07-27
**Supersedes:** nothing
**Promoted from:** issue #6, per theflow's promotion rule (two triggers: an
existing issue's stated premise measured false before work started, and the
reference implementation cannot arbitrate the question).

## Why this is a record and not an issue

An issue holds one decision. This holds a **rule that spans decisions**: which
Windows mechanism a given requirement resolves to, and why the obvious answers
do not work. #6, #7, and any future mechanism question resolve *by construction*
against the table below instead of being re-decided pairwise.

It is also expensive knowledge. Every row was measured on a real unelevated
machine, several of them contradict the documentation, and two of them
contradicted the author's own first measurement. Re-deriving it costs an
afternoon; reading it costs a minute.

## Context

`just_autostart` targets a **console-subsystem executable** — what
`dart compile exe` produces, with no flag to produce anything else. Windows
attaches a console to such a process when it starts, and the console window
appears at every login.

This does not affect the package this one replaces. `launch_at_startup` targets
**Flutter desktop apps**, which are GUI-subsystem binaries; the console window
does not exist for them, so it offers no mechanism for hiding one and its source
is silent on the question. There is no prior art to follow.

## The governing fact

Whether the window appears is decided by **`STARTUPINFO.wShowWindow`**, passed by
whichever process calls `CreateProcess`. Nothing the launched program does at
runtime can change it, and the subsystem is fixed in the PE header at compile
time. So the question is never "how does the program hide its window" but
**"can the launcher be told to pass `SW_HIDE`"**.

## Measurements

All on Windows 11, unelevated (`IsInRole(Administrator) == False`). Visibility
measured as `IsWindowVisible(GetConsoleWindow())` from inside the launched
process.

| Mechanism | Registers unelevated | Hides the console window |
| --- | --- | --- |
| Registry `Run` key | yes | **no** |
| `schtasks /sc ONLOGON` | **no** — `Access is denied` | — |
| `schtasks /create /xml`, `<LogonTrigger><UserId>` | yes | **no** — see below |
| **Task Scheduler COM, `IExecAction::HideAppWindow`** | **yes** | **yes** |
| Task `<LogonType>S4U</LogonType>` (session 0) | **no** — `Access is denied` | — |
| Startup-folder `.lnk`, `SetShowCmd(SW_HIDE)` | yes | **no** — see below |
| Startup-folder `.lnk`, `SetShowCmd(SW_SHOWMINNOACTIVE)` | yes | **no** — minimized is visible |
| `wscript` + `WScript.Shell.Run(cmd, 0, False)` | yes | **yes** |

### `/sc ONLOGON` needs elevation; the XML form does not

The command-line logon trigger is refused for an ordinary user, even scoped with
`/ru <self>`. The same user creates a `/sc ONCE` task in a custom folder without
complaint, so it is the **logon trigger specifically**, not task creation or
folder creation, that is privileged. Supplying the trigger as XML with an
explicit `<LogonTrigger><UserId>` succeeds unelevated.

### `HideAppWindow` exists, is undocumented, and is COM-only

It is absent from the documented `IExecAction`. Enumerated live:

```
IExecAction properties: Arguments, HideAppWindow, Id, Path, Type, WorkingDirectory
```

Registered through COM with `HideAppWindow = true`, the probe reported
`visible=false`.

**The XML round-trip is asymmetric.** Task Scheduler *exports*
`<HideAppWindow>true</HideAppWindow>` in a task's XML, but `schtasks /create /xml`
**rejects it on import**, at every schema version tried:

```
ERROR: The task XML contains an unexpected node.
(6,364):HideAppWindow
version 1.3 -> exit=1
version 1.4 -> exit=1
version 1.5 -> exit=1
```

Exporting a task and importing it again therefore fails. This is documented
nowhere and is visible only by doing both halves.

### `<Hidden>true</Hidden>` is not what its name suggests

It is `TASK_FLAG_HIDDEN` and hides the **task** from the Task Scheduler UI. It has
no effect on the process. A task carrying it still produced `visible=true`.

### The shortcut format cannot represent a hidden window

`IShellLink::SetShowCmd` accepts `SW_HIDE` and then **silently normalizes it on
save**:

```
showCmd requested=0  stored=1     (SW_HIDE      -> SW_SHOWNORMAL)
showCmd requested=7  stored=7     (SW_SHOWMINNOACTIVE persists)
```

Launched through Explorer, both report `visible=true`. This is why the Windows
shortcut UI offers only normal / minimized / maximized.

## Decision

**Task Scheduler through its COM API, called from `dart:ffi`.** It is the only
mechanism that hides the window, needs no elevation, and adds no artifact the
package has to own.

The registry `Run` key stays as the default mechanism (simplest, no external
dependency); Task Scheduler is the opt-in for callers who need the window hidden
or a delayed start.

## Rejected alternatives

**`schtasks` with generated XML** — the route #6 originally specified. Rejected
because `<HideAppWindow>` cannot be imported, so it cannot deliver the one thing
the mechanism exists for. Everything else it offers (delayed start, power
settings) comes along free with the COM route.

**`wscript` + a generated `.vbs`** — measured working, and perhaps a tenth of the
implementation. Rejected because **`wscript.exe` registered in a `Run` key is one
of the most commonly flagged persistence patterns**; shipping it as this
package's answer would get consumers' installations blocked by endpoint
protection. It would also put a second artifact — a script file the package
writes, owns, and must delete — onto the deletion sacred path.

**Startup-folder shortcut** — closed by the format, not merely awkward. See the
measurement above.

**S4U / "run whether the user is logged on or not"** — genuinely solves it by
running in session 0 where no window can be visible, and is what one would reach
for. Refused for an unelevated user.

**Requiring elevation** — would break the invariant recorded in `CLAUDE.md` that
this package never needs it, which `RegistryLocation` already enforces
structurally by not exposing the hive.

## Consequences

*(Currently-true statements. Flip them when the decision flips.)*

- Hiding the console window costs roughly ten COM interfaces — `ITaskService`,
  `ITaskFolder`, `ITaskDefinition`, `ITriggerCollection`, `ILogonTrigger`,
  `IActionCollection`, `IExecAction`, `IExecAction2`, `ITaskSettings`,
  `IRegisteredTask` — plus BSTR and VARIANT marshalling. `Connect` takes four
  VARIANTs and `RegisterTaskDefinition` three, all **by value**, which on x64
  makes the struct's size load-bearing: too small and every argument behind it
  shifts.
- `IPrincipal` turns out not to be needed. Registering with an empty `userId`
  and `TASK_LOGON_INTERACTIVE_TOKEN` already produces a task that runs as the
  registering user, which #6 confirmed against the XML Task Scheduler emits.
- That work sits on this package's **FFI sacred path**, where a wrong vtable
  offset is memory corruption rather than a failing test. The completeness pass
  is mandatory for it regardless of diff size.
- The sibling `just_font_scan` is the in-family precedent for `ole32` COM from
  pure Dart, including `objc`-style handle lifetime discipline.
- Because the work is large it is split: **#6a** builds the COM foundation,
  **#6b** builds the task definition on top.
- A caller who needs the window hidden must choose the Task Scheduler mechanism
  explicitly. The default stays the `Run` key, so the common case pays nothing.
- The package still cannot hide the window for a caller who refuses Task
  Scheduler. That is a documented limitation, not a defect.

## How to re-measure

The probes were disposable and were deleted; the method is what is worth keeping.

1. Compile or run a program that reports
   `IsWindowVisible(GetConsoleWindow())` into a file. **Not
   `GetConsoleWindow() != 0`** — a hidden console still has a handle, so that
   asks the wrong question and reports `true` for every route.
2. Register it by the mechanism under test, in a scratch location
   (`\just_autostart_probe\` for tasks, a scratch key for the registry).
3. Trigger it — `schtasks /run`, `IRegisteredTask.Run`, or `explorer.exe <lnk>`
   for a shortcut, so that Explorer performs the shell resolution the way it does
   at logon.
4. Read the file. Delete every probe and **verify the deletion**.

Enumerate COM properties with `New-Object -ComObject Schedule.Service` and
`Get-Member` rather than trusting the documented interface — that is what
surfaced `HideAppWindow`.
