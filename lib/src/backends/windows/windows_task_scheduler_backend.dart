import 'dart:io';

import '../../autostart_backend.dart';
import '../../autostart_config.dart';
import '../../exceptions.dart';
import '../../list_equals.dart';
import 'task_scheduler.dart';

/// Registers a program at login through Task Scheduler.
///
/// The costlier of the two Windows mechanisms, and the only one that can start a
/// `dart compile exe` program **without a console window**: the window is
/// decided by the `STARTUPINFO.wShowWindow` the launcher passes, and
/// `IExecAction2::HideAppWindow` is how the Task Scheduler service is told to
/// pass `SW_HIDE`. It can also delay the start so the program does not compete
/// with the rest of the login sequence. `docs/adr/0001-windows-autostart-mechanisms.md`
/// records why no other unelevated mechanism can do either.
///
/// Which mechanism to use is the calling application's decision, not this
/// package's — there is no automatic fallback between them.
final class WindowsTaskSchedulerBackend implements AutostartBackend {
  /// Creates a backend for [config].
  ///
  /// [hideWindow] and [delay] are the two reasons to choose this mechanism at
  /// all. [scheduler] is the single seam: tests point it at a scratch folder and
  /// run the real COM calls against it.
  const WindowsTaskSchedulerBackend({
    required this.config,
    this.hideWindow = true,
    this.delay,
    this.scheduler = const WindowsTaskScheduler(),
  });

  /// What to register.
  final AutostartConfig config;

  /// Whether the launched program's console window is hidden.
  final bool hideWindow;

  /// How long after logon to wait, or `null` to start at once.
  final Duration? delay;

  /// How Task Scheduler is reached.
  final WindowsTaskScheduler scheduler;

  /// The task name, which is [AutostartConfig.appName].
  ///
  /// The same string the `Run` key uses for its value name, so a user sees one
  /// name whichever mechanism is in force.
  String get _taskName => config.appName;

  /// Registers the task, replacing any earlier one under the same name.
  ///
  /// Registering over an existing task also **clears a veto the user set** in
  /// the Task Scheduler UI — measured, and the same behaviour `enable()` has on
  /// the `Run` key, where it rewrites the `StartupApproved` value. The calling
  /// application is expected to have asked its user first.
  @override
  Future<void> enable() async {
    _requireUsableTaskName();

    if (!File(config.executablePath).existsSync()) {
      throw ExecutableNotFoundException(config.executablePath);
    }

    scheduler.createTask(
      _taskName,
      TaskRegistration(
        executablePath: config.executablePath,
        args: config.args,
        hideWindow: hideWindow,
        delay: delay,
      ),
    );
  }

  /// Removes this application's task, and only this application's.
  ///
  /// The task folder is a **shared namespace keyed by a name assembled from
  /// caller-supplied text**, exactly as the `Run` key is, so the guard is the
  /// same one and for the same reason: the stored task is removed only when its
  /// action **names the configured executable**. Deleting on a name match alone
  /// would destroy another application's autostart with no way back.
  ///
  /// The cost is the same too — a task left behind by an **earlier install at a
  /// different path** is not cleaned up here. `enable()` overwrites it and a
  /// user can delete it from the Task Scheduler UI. One stale task beats
  /// deleting a third party's.
  @override
  Future<void> disable() async {
    if (!_isOurs(scheduler.readTask(_taskName))) return;

    scheduler.deleteTask(_taskName);
  }

  /// Whether the executable will actually launch at login.
  ///
  /// Four things have to hold, and only the first is about the registration
  /// existing:
  ///
  /// 1. the task is there;
  /// 2. the **task** is enabled — a user can switch it off in the Task
  ///    Scheduler UI without deleting it, the same "registered versus
  ///    permitted" split the `Run` key handles through its approval value;
  /// 3. it has an enabled **logon trigger** — a *different* switch in the same
  ///    UI, and a task whose trigger is off, missing, or of another type is
  ///    enabled and still never starts at login;
  /// 4. its action names the configured executable and arguments — a task left
  ///    by an older install would launch the wrong program.
  ///
  /// Dropping any one of them reports a program that cannot run as enabled.
  @override
  Future<bool> isEnabled() async {
    final task = scheduler.readTask(_taskName);
    if (task == null) return false;
    if (!task.enabled) return false;
    if (!task.startsAtLogon) return false;
    if (!_isOurs(task)) return false;

    // `null` arguments mean the stored tail did not parse, which is not a shape
    // this package writes — so it is somebody else's task, not a match.
    final args = task.args;
    if (args == null) return false;

    return listEquals(args, config.args);
  }

  /// Refuses an [AutostartConfig.appName] this mechanism cannot use as a name.
  ///
  /// A separator makes Task Scheduler read the name as a **path**: `Sub\Tool`
  /// silently creates a subfolder inside this package's folder, and that
  /// subfolder then outlives `disable()` — which removes the task and leaves
  /// the folder, after which `deleteFolder()` fails because the parent is no
  /// longer empty. The `Run` key has no such reading of the same string, so
  /// this is checked here rather than in the shared configuration.
  ///
  /// Throws [ArgumentError], following the convention that a value the calling
  /// program chose and could have checked is a programmer error.
  void _requireUsableTaskName() {
    if (_taskName.contains(r'\') || _taskName.contains('/')) {
      throw ArgumentError.value(
        _taskName,
        'appName',
        'must not contain a path separator when using Task Scheduler — '
            'the name is read as a folder path',
      );
    }
  }

  /// Whether [task] is this application's to act on.
  ///
  /// Weaker than [isEnabled] on purpose: the arguments may have changed between
  /// releases, and a task this application owns is still its own to remove.
  bool _isOurs(RegisteredTask? task) {
    final path = task?.executablePath;
    if (path == null) return false;

    // Windows paths are case-insensitive, so a task registered as
    // `C:\App\app.exe` launches the same file as `c:\app\APP.exe`.
    return path.toLowerCase() == config.executablePath.toLowerCase();
  }
}
