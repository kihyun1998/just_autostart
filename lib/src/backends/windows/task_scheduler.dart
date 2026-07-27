import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
import 'com.dart';
import 'current_user.dart';
import 'run_command_line.dart';

/// The Task Scheduler folder this package registers into by default.
///
/// A folder of its own rather than the root, so a registration is attributable
/// and so uninstalling can remove the folder without touching anything else.
const String defaultTaskFolderPath = r'\just_autostart';

/// Where in the Task Scheduler tree this package's tasks live.
///
/// This is the seam. Tests point it at a scratch folder and run the real COM
/// calls against it: a test that passed against a faked Task Scheduler would
/// say nothing about whether the vtable indices are right, which is the single
/// most likely thing to be wrong here.
///
/// The path is always below the **root of the current machine's task tree**,
/// reached as the logged-on user. There is no seam for a different user or a
/// different machine, which is what makes "this package never needs elevation"
/// structural rather than a promise.
final class TaskFolder {
  /// Creates a folder location at [path].
  ///
  /// [path] must begin with `\`, name at least one folder below the root, and
  /// not end with a separator. Those are not stylistic rules.
  /// [WindowsTaskScheduler.deleteFolder] hands [relativePath] to
  /// `ITaskFolder::DeleteFolder` on the **root**, and a path of `\` alone
  /// reduces to the empty string there — which is the root itself, holding
  /// every scheduled task Windows and every other application have registered.
  /// This is the deletion sacred path.
  ///
  /// The root itself is rejected at **compile time**, because every real use of
  /// this constructor is a `const` invocation and `==` on strings is one of the
  /// few operations a `const` assert can evaluate. The remaining rules cannot
  /// be checked here — `[]`, `substring` and `startsWith` are not constant
  /// expressions — so they are enforced by [relativePath], which every path
  /// that reaches `CreateFolder` or `DeleteFolder` goes through. Deliberately a
  /// plain `throw` and not another assert: this one must survive into a release
  /// build.
  const TaskFolder(this.path)
    : assert(
        path != r'\',
        'the task folder must be below the root, not the root',
      );

  /// The folder path, beginning with `\`.
  final String path;

  /// The path with its leading separator removed, which is the form
  /// `ITaskFolder::CreateFolder` and `::DeleteFolder` expect relative to the
  /// root.
  ///
  /// Throws [ArgumentError] when [path] is not a folder below the root. The
  /// folder is chosen by this package or by a test and never by an end user, so
  /// a bad one is a programmer error — but it is one with no undo, so it is
  /// caught rather than passed on.
  String get relativePath {
    if (path.length < 2 || !path.startsWith(r'\') || path.endsWith(r'\')) {
      throw ArgumentError.value(
        path,
        'path',
        'must name a folder below the root, as "\\Name"',
      );
    }
    return path.substring(1);
  }

  @override
  bool operator ==(Object other) => other is TaskFolder && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'TaskFolder($path)';
}

/// What a task launches at logon, and how.
final class TaskRegistration {
  /// Describes a task that runs [executablePath] with [args].
  const TaskRegistration({
    required this.executablePath,
    this.args = const [],
    this.hideWindow = true,
    this.delay,
  });

  /// The program the task starts.
  final String executablePath;

  /// The arguments it is started with.
  final List<String> args;

  /// Whether the launched process's window is hidden.
  ///
  /// The reason this mechanism exists. `dart compile exe` produces a
  /// console-subsystem executable and the subsystem is fixed at compile time,
  /// so the console window is decided by the `STARTUPINFO.wShowWindow` the
  /// *launcher* passes — and `IExecAction2::HideAppWindow` is how the Task
  /// Scheduler service is told to pass `SW_HIDE`. See ADR-0001.
  final bool hideWindow;

  /// How long after logon to wait before starting, or `null` to start at once.
  final Duration? delay;
}

/// What a registered task reports about itself when read back.
final class RegisteredTask {
  /// Describes a task as Task Scheduler currently holds it.
  const RegisteredTask({
    required this.executablePath,
    required this.args,
    required this.enabled,
    required this.startsAtLogon,
  });

  /// The program its first action runs, or `null` when it has no readable
  /// executable action — which is what a task belonging to something else
  /// generally looks like.
  final String? executablePath;

  /// The arguments that action carries, or `null` when they could not be read
  /// or did not parse.
  final List<String>? args;

  /// Whether the task will actually run.
  ///
  /// **This is the second store.** A user can switch a task off in the Task
  /// Scheduler UI without deleting it, exactly as they can switch a `Run` key
  /// entry off in Task Manager — and, exactly as there, the registration is
  /// left untouched and says nothing about it.
  final bool enabled;

  /// Whether the task carries a logon trigger that is itself enabled.
  ///
  /// **This is the third store, and it is a different switch from [enabled].**
  /// The Task Scheduler UI can disable the *task* (the command on the task) and
  /// it can disable a *trigger* (Properties → Triggers → Edit), and neither
  /// touches the other. A task that is enabled but whose only trigger is
  /// disabled — or which has no trigger at all, or only a trigger that is not a
  /// logon trigger — is registered, permitted, and will never start at login.
  ///
  /// Reading [enabled] alone reports such a task as on, which is the same lie
  /// the `Run` key's approval value exists to prevent, one level deeper.
  final bool startsAtLogon;

  @override
  String toString() =>
      'RegisteredTask(executablePath: $executablePath, args: $args, '
      'enabled: $enabled, startsAtLogon: $startsAtLogon)';
}

/// Formats [duration] as the ISO 8601 duration Task Scheduler stores.
///
/// `ILogonTrigger::Delay` is a `BSTR`, not a number of seconds, and Task
/// Scheduler rejects anything that is not in this form rather than coercing it.
/// Zero is `PT0S` — the spelling matters, because an empty string means "no
/// delay set" and is a different state from "a delay of nothing".
///
/// Throws [ArgumentError] for a negative duration, and for a non-zero duration
/// shorter than one second.
///
/// Neither has a representation here. The sub-second case is the one worth
/// naming: it *looks* representable, and an earlier version of this produced
/// the bare string `"PT"` for it — which `put_Delay` accepts without complaint
/// and `RegisterTaskDefinition` then rejects with a message that never mentions
/// the delay. Rounding it to `PT0S` would be worse still, because `PT0S` is the
/// spelling this package uses to mean "no limit".
String encodeTaskDuration(Duration duration) {
  if (duration.isNegative) {
    throw ArgumentError.value(duration, 'duration', 'must not be negative');
  }
  if (duration == Duration.zero) return 'PT0S';
  if (duration < const Duration(seconds: 1)) {
    throw ArgumentError.value(
      duration,
      'duration',
      'must be zero or at least one second — this format has no smaller unit',
    );
  }

  final buffer = StringBuffer('PT');
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  if (hours > 0) buffer.write('${hours}H');
  if (minutes > 0) buffer.write('${minutes}M');
  if (seconds > 0) buffer.write('${seconds}S');
  return buffer.toString();
}

/// Creates, finds and removes scheduled tasks through the Task Scheduler COM
/// API, called from `dart:ffi`.
///
/// **Every method here is synchronous, and that is a requirement rather than a
/// style.** COM's apartment is per-thread state, and a Dart isolate is not
/// pinned to an OS thread across event-loop turns; [withCom] therefore opens
/// and closes the apartment around one synchronous block. An `await` inside
/// that block could resume on a thread where COM was never initialised. A
/// caller that needs a `Future` wraps the completed result, and does not make
/// these methods `async`.
///
/// There is no interface over this and no fake of it. The dangerous part *is*
/// the vtable dispatch, so the tests drive the real Task Scheduler at a scratch
/// folder.
final class WindowsTaskScheduler {
  /// Creates a scheduler that operates inside [folder].
  const WindowsTaskScheduler({
    this.folder = const TaskFolder(defaultTaskFolderPath),
  });

  /// The folder tasks are created in, found in, and deleted from.
  final TaskFolder folder;

  /// Registers a task named [name] that runs [registration] at logon.
  ///
  /// The whole definition is written here — the logon trigger confined to this
  /// user, the principal, the settings whose defaults would stop a daemon, and
  /// the action with its window flag. Nothing is left to Task Scheduler's
  /// defaults except the ones measured to be right.
  ///
  /// Registering an existing name updates it rather than failing, so a caller
  /// can enable an already-enabled program without special-casing it. Measured:
  /// that update also **clears a user's veto** — a task switched off in the Task
  /// Scheduler UI comes back enabled. That is the same behaviour `enable()` has
  /// on the `Run` key, where it rewrites the `StartupApproved` value, reached by
  /// a different route and consistent with it by luck rather than by design.
  /// Recorded because it is the kind of thing a future change could silently
  /// reverse.
  ///
  /// **The Task Scheduler tree is machine-wide, and the `Run` key is not.**
  /// `HKCU\…\Run` isolates two users of the same application from each other for
  /// free; `\just_autostart\<name>` does not. Measured on a real machine: the
  /// folder inherits `Authenticated Users:(W)`, so a second user *can* create
  /// tasks in it, but the task file itself grants full control only to whoever
  /// created it — so the second user's registration fails with access denied
  /// rather than overwriting the first. A loud failure, not silent data loss,
  /// but still a limitation. Choosing a name that separates users is the job of
  /// whatever decides the task name.
  void createTask(String name, TaskRegistration registration) {
    _withFolder(create: true, (arena, service, folder) {
      final definition = _newTask(arena, service);
      _setPrincipal(arena, definition);
      _setSettings(arena, definition);
      _setLogonTrigger(arena, definition, registration.delay);
      _setExecAction(arena, definition, registration);

      final registered = arena<ComPtr>();
      final hr =
          vtableSlot<
                Int32 Function(
                  ComPtr,
                  Pointer<Utf16>,
                  ComPtr,
                  Int32,
                  Variant,
                  Variant,
                  Int32,
                  Variant,
                  Pointer<ComPtr>,
                )
              >(folder, _folderRegisterTaskDefinition)
              .asFunction<
                int Function(
                  ComPtr,
                  Pointer<Utf16>,
                  ComPtr,
                  int,
                  Variant,
                  Variant,
                  int,
                  Variant,
                  Pointer<ComPtr>,
                )
              >()(
            folder,
            allocateBstr(arena, name),
            definition,
            _taskCreateOrUpdate,
            // No user, no password and no security descriptor. Combined with
            // an interactive-token logon, that registers the task for whoever
            // is running this code — the only form that needs no privilege.
            emptyVariant(arena).ref,
            emptyVariant(arena).ref,
            _taskLogonInteractiveToken,
            emptyVariant(arena).ref,
            registered,
          );
      checkHResult(hr, 'ITaskFolder::RegisterTaskDefinition');
      ownInterface(arena, registered.value);
    });
  }

  /// Whether a task named [name] is **registered** in [folder].
  ///
  /// A folder that does not exist reads as "no task" rather than as a failure:
  /// that is the state of a machine where this package has never run.
  ///
  /// **Registered is not the same as enabled, and this answers the first
  /// question only.** A user can switch a task off in the Task Scheduler UI,
  /// which leaves it registered and stops it running — the same shape as the
  /// `Run` key's `StartupApproved` veto, in a different store. Reading that
  /// veto means `IRegisteredTask::get_Enabled`, and it belongs to whatever
  /// implements `isEnabled()` on top of this. A backend that reports this
  /// method's answer as "autostart is on" would be repeating the exact lie the
  /// `Run` key backend exists to avoid.
  bool taskExists(String name) => readTask(name) != null;

  /// Reads back what the task named [name] holds, or `null` when there is none.
  ///
  /// This is the read every decision rests on. `isEnabled()` needs all three
  /// answers — the task is there, it is *enabled*, and its action names the
  /// configured program — and `disable()` needs the third on its own, because
  /// the folder is a shared namespace and a name match is not ownership.
  RegisteredTask? readTask(String name) {
    return _withFolder(create: false, (arena, service, folder) {
      if (folder == nullptr) return null;
      return _read(arena, folder, name);
    });
  }

  /// Removes the task named [name], reporting whether there was one.
  ///
  /// Returns `false` when the task or the folder was already absent, so a
  /// caller can stay idempotent without inspecting error codes.
  bool deleteTask(String name) {
    return _withFolder(create: false, (arena, service, folder) {
      if (folder == nullptr) return false;
      return _delete(arena, folder, _folderDeleteTask, name, 'DeleteTask');
    });
  }

  /// Removes [folder] itself, reporting whether there was one.
  ///
  /// Task Scheduler refuses to remove a folder that still holds tasks, and that
  /// refusal is surfaced rather than worked around: a folder that is not empty
  /// may be shared with something else, and emptying it is not this package's
  /// call to make.
  bool deleteFolder() {
    return _withRoot((arena, service, root) {
      return _delete(
        arena,
        root,
        _folderDeleteFolder,
        folder.relativePath,
        'DeleteFolder',
      );
    });
  }

  /// `ITaskFolder::DeleteTask` and `::DeleteFolder`, which differ only in the
  /// slot they occupy: both take a name and a flags word, both report an absent
  /// target the same way. Written once so the absent-versus-failed distinction
  /// — the part with consequences — exists in one place.
  ///
  /// Returns `false` when there was nothing to delete.
  bool _delete(
    Arena arena,
    ComPtr self,
    int slot,
    String name,
    String operation,
  ) {
    final hr =
        vtableSlot<Int32 Function(ComPtr, Pointer<Utf16>, Int32)>(
          self,
          slot,
        ).asFunction<int Function(ComPtr, Pointer<Utf16>, int)>()(
          self,
          allocateBstr(arena, name),
          0,
        );
    if (reportsAbsent(hr)) return false;
    checkHResult(hr, 'ITaskFolder::$operation');
    return true;
  }

  /// Runs [body] with a connected `ITaskService` and the root task folder.
  T _withRoot<T>(T Function(Arena arena, ComPtr service, ComPtr root) body) {
    return withCom(() {
      return using((arena) {
        final service = createInstance(
          arena,
          _clsidTaskScheduler,
          _iidTaskService,
        );
        _connectToLocalMachine(arena, service);

        // The root always exists, so a `null` here would mean Task Scheduler
        // itself is in a state this package has no model for. Reported as this
        // package's own failure type rather than left to become a null-check
        // `TypeError`: every failure crossing this boundary is documented as an
        // `AutostartException`, and "the root folder is missing" should not be
        // the one exception to that.
        final root = _folderAt(arena, service, r'\');
        if (root == null) {
          throw const AutostartOsException(
            operation: 'ITaskService::GetFolder',
            detail: 'the root task folder does not exist',
          );
        }
        return body(arena, service, root);
      });
    });
  }

  /// Runs [body] with [folder], creating it when [create] is set.
  ///
  /// When the folder is absent and [create] is not set, [body] receives
  /// [nullptr] — the callers that read rather than write turn that into "no".
  T _withFolder<T>(
    T Function(Arena arena, ComPtr service, ComPtr folder) body, {
    required bool create,
  }) {
    return _withRoot((arena, service, root) {
      final existing = _folderAt(arena, service, folder.path);
      if (existing != null) return body(arena, service, existing);
      if (!create) return body(arena, service, nullptr);

      return body(arena, service, _createFolder(arena, root));
    });
  }

  /// `ITaskService::Connect` with four empty variants — the local machine, as
  /// the user already logged on.
  void _connectToLocalMachine(Arena arena, ComPtr service) {
    final hr =
        vtableSlot<Int32 Function(ComPtr, Variant, Variant, Variant, Variant)>(
              service,
              _serviceConnect,
            )
            .asFunction<
              int Function(ComPtr, Variant, Variant, Variant, Variant)
            >()(
          service,
          emptyVariant(arena).ref,
          emptyVariant(arena).ref,
          emptyVariant(arena).ref,
          emptyVariant(arena).ref,
        );
    checkHResult(hr, 'ITaskService::Connect');
  }

  /// `ITaskService::GetFolder`, returning `null` when the folder is not there.
  ComPtr? _folderAt(Arena arena, ComPtr service, String path) => _lookUp(
    arena,
    service,
    _serviceGetFolder,
    path,
    'ITaskService::GetFolder',
  );

  /// `ITaskFolder::GetTask`, returning `null` when the task is not there.
  ComPtr? _getTask(Arena arena, ComPtr folder, String name) =>
      _lookUp(arena, folder, _folderGetTask, name, 'ITaskFolder::GetTask');

  /// `GetFolder` and `GetTask`, which differ only in the slot they occupy: both
  /// take a name and return an interface, both report an absent target the same
  /// way. Written once so the absent-versus-failed distinction exists in one
  /// place, and so the returned pointer is registered for release in one place.
  ComPtr? _lookUp(
    Arena arena,
    ComPtr self,
    int slot,
    String name,
    String operation,
  ) {
    final result = arena<ComPtr>();
    final hr =
        vtableSlot<Int32 Function(ComPtr, Pointer<Utf16>, Pointer<ComPtr>)>(
          self,
          slot,
        ).asFunction<int Function(ComPtr, Pointer<Utf16>, Pointer<ComPtr>)>()(
          self,
          allocateBstr(arena, name),
          result,
        );
    if (reportsAbsent(hr)) return null;
    checkHResult(hr, operation);
    return ownInterface(arena, result.value);
  }

  /// `ITaskFolder::CreateFolder` on the root, for [folder].
  ///
  /// Only reached when [_folderAt] has already reported the folder absent, so
  /// an "already exists" answer here is not expected and is not special-cased —
  /// it would mean something else created it in between, which is worth
  /// surfacing rather than swallowing.
  ComPtr _createFolder(Arena arena, ComPtr root) {
    final result = arena<ComPtr>();
    final hr =
        vtableSlot<
              Int32 Function(ComPtr, Pointer<Utf16>, Variant, Pointer<ComPtr>)
            >(root, _folderCreateFolder)
            .asFunction<
              int Function(ComPtr, Pointer<Utf16>, Variant, Pointer<ComPtr>)
            >()(
          root,
          allocateBstr(arena, folder.relativePath),
          // No security descriptor: the folder inherits, which for a folder
          // under the current user's control is what is wanted.
          emptyVariant(arena).ref,
          result,
        );
    checkHResult(hr, 'ITaskFolder::CreateFolder');
    return ownInterface(arena, result.value);
  }

  /// `ITaskService::NewTask` — an empty, unregistered task definition.
  ComPtr _newTask(Arena arena, ComPtr service) {
    final result = arena<ComPtr>();
    final hr =
        vtableSlot<Int32 Function(ComPtr, Uint32, Pointer<ComPtr>)>(
          service,
          _serviceNewTask,
        ).asFunction<int Function(ComPtr, int, Pointer<ComPtr>)>()(
          service,
          0, // reserved, and documented as required to be zero
          result,
        );
    checkHResult(hr, 'ITaskService::NewTask');
    return ownInterface(arena, result.value);
  }

  /// Names the account the task runs as.
  ///
  /// Measured on a fresh definition: `LogonType` is already
  /// `TASK_LOGON_INTERACTIVE_TOKEN` and `RunLevel` is already
  /// `TASK_RUNLEVEL_LUA`, so both of these writes are redundant *today*. They
  /// are written anyway, because "the default happened to be right" is not the
  /// same guarantee as "this package asked for it" — and least privilege is not
  /// a property to inherit silently.
  void _setPrincipal(Arena arena, ComPtr definition) {
    final principal = _property(
      arena,
      definition,
      _definitionGetPrincipal,
      'ITaskDefinition::get_Principal',
    );

    _putBstr(
      arena,
      principal,
      _principalPutUserId,
      currentUserSid(),
      'IPrincipal::put_UserId',
    );
    _putInt(
      arena,
      principal,
      _principalPutLogonType,
      _taskLogonInteractiveToken,
      'IPrincipal::put_LogonType',
    );
    _putInt(
      arena,
      principal,
      _principalPutRunLevel,
      _taskRunLevelLua,
      'IPrincipal::put_RunLevel',
    );
  }

  /// Replaces the settings whose defaults are wrong for a program that is meant
  /// to start at login and keep running.
  ///
  /// Every value here was measured on a fresh definition, and none of them
  /// appear in the XML Task Scheduler exports — so a task that looks empty is
  /// carrying all of them:
  ///
  /// - `DisallowStartIfOnBatteries` and `StopIfGoingOnBatteries` are `true`, so
  ///   an unplugged laptop never starts the program and unplugging stops it.
  /// - `ExecutionTimeLimit` is `PT72H`, and `AllowHardTerminate` is `true`, so
  ///   a **daemon** — the thing this package exists to start — is killed after
  ///   three days. `PT0S` is the spelling for no limit.
  /// - `StartWhenAvailable` is `false`. Microsoft documents this as governing
  ///   *scheduled* start times, and neither the documentation nor the SDK
  ///   header says what it does for a logon trigger — so it is set to `true` on
  ///   the grounds that "start it late rather than not at all" is the answer
  ///   this package wants wherever the setting applies, and **not** on a claim
  ///   about what it does here. Settling that would take a suspend-and-log-on
  ///   probe of the kind ADR-0001 records.
  void _setSettings(Arena arena, ComPtr definition) {
    final settings = _property(
      arena,
      definition,
      _definitionGetSettings,
      'ITaskDefinition::get_Settings',
    );

    _putBool(
      arena,
      settings,
      _settingsPutDisallowStartIfOnBatteries,
      false,
      'ITaskSettings::put_DisallowStartIfOnBatteries',
    );
    _putBool(
      arena,
      settings,
      _settingsPutStopIfGoingOnBatteries,
      false,
      'ITaskSettings::put_StopIfGoingOnBatteries',
    );
    _putBool(
      arena,
      settings,
      _settingsPutStartWhenAvailable,
      true,
      'ITaskSettings::put_StartWhenAvailable',
    );
    _putBstr(
      arena,
      settings,
      _settingsPutExecutionTimeLimit,
      encodeTaskDuration(Duration.zero),
      'ITaskSettings::put_ExecutionTimeLimit',
    );

    // Clearing a veto the user set from the Task Scheduler UI. Registering over
    // an existing task replaces the whole definition, so a fresh `true` already
    // arrives by default — but this is the pinned product decision that
    // `enable()` overrides the user, and a decision is asked for rather than
    // inherited from a default that could change.
    _putBool(
      arena,
      settings,
      _settingsPutEnabled,
      true,
      'ITaskSettings::put_Enabled',
    );
  }

  /// Adds the logon trigger, confined to the user who registered the task.
  ///
  /// **The `UserId` is not optional.** A logon trigger without one fires when
  /// *any* account logs on, and the task then runs as its principal — so a
  /// second user signing in would start the first user's program.
  void _setLogonTrigger(Arena arena, ComPtr definition, Duration? delay) {
    final triggers = _property(
      arena,
      definition,
      _definitionGetTriggers,
      'ITaskDefinition::get_Triggers',
    );
    final created = _create(
      arena,
      triggers,
      _triggersCreate,
      _taskTriggerLogon,
      'ITriggerCollection::Create',
    );
    final trigger = queryInterface(
      arena,
      created,
      _iidLogonTrigger,
      'ITrigger::QueryInterface(ILogonTrigger)',
    );

    _putBstr(
      arena,
      trigger,
      _logonTriggerPutUserId,
      currentUserSid(),
      'ILogonTrigger::put_UserId',
    );
    if (delay != null) {
      _putBstr(
        arena,
        trigger,
        _logonTriggerPutDelay,
        encodeTaskDuration(delay),
        'ILogonTrigger::put_Delay',
      );
    }
  }

  /// Gives [definition] the single action that runs the configured program.
  void _setExecAction(
    Arena arena,
    ComPtr definition,
    TaskRegistration registration,
  ) {
    final actions = _property(
      arena,
      definition,
      _definitionGetActions,
      'ITaskDefinition::get_Actions',
    );
    final action = _create(
      arena,
      actions,
      _actionsCreate,
      _taskActionExec,
      'IActionCollection::Create',
    );

    // `Create` hands back an `IAction`, and `IExecAction` extends it, so the
    // slot for `put_Path` would be reachable through the pointer as it stands.
    // Asking for the interface anyway is the point: a `QueryInterface` failure
    // says the object is not what this code assumes, where a bare vtable call
    // through the wrong assumption says nothing at all.
    final execAction = queryInterface(
      arena,
      action,
      _iidExecAction,
      'IAction::QueryInterface(IExecAction)',
    );

    _putBstr(
      arena,
      execAction,
      _execActionPutPath,
      registration.executablePath,
      'IExecAction::put_Path',
    );
    _putBstr(
      arena,
      execAction,
      _execActionPutArguments,
      encodeArguments(registration.args),
      'IExecAction::put_Arguments',
    );

    if (!registration.hideWindow) return;

    // The reason this whole mechanism exists, and the one property that is not
    // on the documented `IExecAction` — it lives on `IExecAction2`, which the
    // SDK header declares and the documentation does not. See ADR-0001.
    final execAction2 = queryInterface(
      arena,
      execAction,
      _iidExecAction2,
      'IExecAction::QueryInterface(IExecAction2)',
    );
    _putBool(
      arena,
      execAction2,
      _execAction2PutHideAppWindow,
      true,
      'IExecAction2::put_HideAppWindow',
    );
  }

  /// Reads back what a registered task actually says about itself.
  ///
  /// Returns `null` when there is no such task. A task that exists but whose
  /// first action is not an executable action — someone else's task under a
  /// colliding name — reports a `null` [RegisteredTask.executablePath] rather
  /// than raising, because both callers read "not ours" from it and neither
  /// should fail over another application's task.
  RegisteredTask? _read(Arena arena, ComPtr folder, String name) {
    final task = _getTask(arena, folder, name);
    if (task == null) return null;

    final enabled = _getBool(
      arena,
      task,
      _registeredTaskGetEnabled,
      'IRegisteredTask::get_Enabled',
    );

    final definition = _property(
      arena,
      task,
      _registeredTaskGetDefinition,
      'IRegisteredTask::get_Definition',
    );
    final startsAtLogon = _hasEnabledLogonTrigger(arena, definition);
    final actions = _property(
      arena,
      definition,
      _definitionGetActions,
      'ITaskDefinition::get_Actions',
    );

    RegisteredTask unrecognised() => RegisteredTask(
      executablePath: null,
      args: null,
      enabled: enabled,
      startsAtLogon: startsAtLogon,
    );

    // This package writes **exactly one** action, so a task carrying any other
    // number is not one it wrote — whatever the first action happens to say.
    // Checking the count as well as the first action is what stops `disable()`
    // destroying a foreign task that merely begins the way ours does; the extra
    // actions would go with it and there is no undo.
    if (_count(arena, actions, _actionsGetCount, 'IActionCollection') != 1) {
      return unrecognised();
    }

    // COM collections are 1-based.
    final first = arena<ComPtr>();
    final hr =
        vtableSlot<Int32 Function(ComPtr, Int32, Pointer<ComPtr>)>(
          actions,
          _actionsGetItem,
        ).asFunction<int Function(ComPtr, int, Pointer<ComPtr>)>()(
          actions,
          1,
          first,
        );
    if (!succeeded(hr) || first.value == nullptr) return unrecognised();
    final action = ownInterface(arena, first.value);

    // A non-executable action — a COM handler, a message box — does not answer
    // to `IExecAction`, and that is the honest signal that the task is not ours.
    final ComPtr execAction;
    try {
      execAction = queryInterface(
        arena,
        action,
        _iidExecAction,
        'IAction::QueryInterface(IExecAction)',
      );
    } on AutostartOsException {
      return unrecognised();
    }

    final path = _getBstr(
      arena,
      execAction,
      _execActionGetPath,
      'IExecAction::get_Path',
    );
    final arguments = _getBstr(
      arena,
      execAction,
      _execActionGetArguments,
      'IExecAction::get_Arguments',
    );

    return RegisteredTask(
      executablePath: path,
      args: arguments == null ? const [] : decodeArguments(arguments),
      enabled: enabled,
      startsAtLogon: startsAtLogon,
    );
  }

  /// Whether [definition] carries a logon trigger that is itself switched on.
  ///
  /// The **third store**. A user can disable a trigger from the Task Scheduler
  /// UI without disabling the task, and a task can be registered with no
  /// trigger at all or with a trigger of some other type. In every one of those
  /// states the task exists, is enabled, and never starts at login — so a
  /// backend that reads only `IRegisteredTask::get_Enabled` reports a program
  /// that can never run as enabled.
  bool _hasEnabledLogonTrigger(Arena arena, ComPtr definition) {
    final triggers = _property(
      arena,
      definition,
      _definitionGetTriggers,
      'ITaskDefinition::get_Triggers',
    );

    final count = _count(
      arena,
      triggers,
      _triggersGetCount,
      'ITriggerCollection',
    );
    for (var index = 1; index <= count; index++) {
      final item = arena<ComPtr>();
      final hr =
          vtableSlot<Int32 Function(ComPtr, Int32, Pointer<ComPtr>)>(
            triggers,
            _triggersGetItem,
          ).asFunction<int Function(ComPtr, int, Pointer<ComPtr>)>()(
            triggers,
            index,
            item,
          );
      if (!succeeded(hr) || item.value == nullptr) continue;
      final trigger = ownInterface(arena, item.value);

      final type = _getInt(
        arena,
        trigger,
        _triggerGetType,
        'ITrigger::get_Type',
      );
      if (type != _taskTriggerLogon) continue;

      if (_getBool(
        arena,
        trigger,
        _triggerGetEnabled,
        'ITrigger::get_Enabled',
      )) {
        return true;
      }
    }
    return false;
  }
}

// --- Property accessors ------------------------------------------------------
//
// Every one of these is `vtableSlot<N>(…).asFunction<D>()(…)`, whose repetition
// is not extractable — `asFunction` needs both signatures spelled at the call
// site, and that is exactly what makes the call type-safe. What *is* extractable
// is one helper per distinct signature, which is what these are: written once,
// so a marshalling mistake exists in one place rather than in each of the
// fourteen calls that share its shape.

/// A property whose value is an interface — `get_Actions`, `get_Settings`.
ComPtr _property(Arena arena, ComPtr self, int slot, String operation) {
  final result = arena<ComPtr>();
  checkHResult(
    vtableSlot<Int32 Function(ComPtr, Pointer<ComPtr>)>(
      self,
      slot,
    ).asFunction<int Function(ComPtr, Pointer<ComPtr>)>()(self, result),
    operation,
  );
  return ownInterface(arena, result.value);
}

/// `Create(type, out)` on a trigger or action collection.
ComPtr _create(Arena arena, ComPtr self, int slot, int type, String operation) {
  final result = arena<ComPtr>();
  checkHResult(
    vtableSlot<Int32 Function(ComPtr, Int32, Pointer<ComPtr>)>(
      self,
      slot,
    ).asFunction<int Function(ComPtr, int, Pointer<ComPtr>)>()(
      self,
      type,
      result,
    ),
    operation,
  );
  return ownInterface(arena, result.value);
}

void _putBstr(
  Arena arena,
  ComPtr self,
  int slot,
  String value,
  String operation,
) {
  checkHResult(
    vtableSlot<Int32 Function(ComPtr, Pointer<Utf16>)>(
      self,
      slot,
    ).asFunction<int Function(ComPtr, Pointer<Utf16>)>()(
      self,
      allocateBstr(arena, value),
    ),
    operation,
  );
}

String? _getBstr(Arena arena, ComPtr self, int slot, String operation) {
  final result = arena<Pointer<Utf16>>();
  checkHResult(
    vtableSlot<Int32 Function(ComPtr, Pointer<Pointer<Utf16>>)>(
      self,
      slot,
    ).asFunction<int Function(ComPtr, Pointer<Pointer<Utf16>>)>()(self, result),
    operation,
  );
  if (result.value == nullptr) return null;

  // The BSTR is the callee's, allocated by the OLE automation allocator, so it
  // is copied out and then freed with that allocator — the arena has no claim
  // on it and freeing it any other way would cross allocators.
  final text = result.value.toDartString();
  freeBstr(result.value);
  return text;
}

void _putBool(
  Arena arena,
  ComPtr self,
  int slot,
  bool value,
  String operation,
) {
  checkHResult(
    vtableSlot<Int32 Function(ComPtr, Int16)>(
      self,
      slot,
    ).asFunction<int Function(ComPtr, int)>()(
      self,
      value ? _variantTrue : _variantFalse,
    ),
    operation,
  );
}

bool _getBool(Arena arena, ComPtr self, int slot, String operation) {
  final result = arena<Int16>();
  checkHResult(
    vtableSlot<Int32 Function(ComPtr, Pointer<Int16>)>(
      self,
      slot,
    ).asFunction<int Function(ComPtr, Pointer<Int16>)>()(self, result),
    operation,
  );
  // Anything non-zero is true. `VARIANT_BOOL`'s canonical true is -1, but a
  // value that came from somewhere else need not be canonical.
  return result.value != _variantFalse;
}

int _getInt(Arena arena, ComPtr self, int slot, String operation) {
  final result = arena<Int32>();
  checkHResult(
    vtableSlot<Int32 Function(ComPtr, Pointer<Int32>)>(
      self,
      slot,
    ).asFunction<int Function(ComPtr, Pointer<Int32>)>()(self, result),
    operation,
  );
  return result.value;
}

/// `get_Count` on a collection, which every one of them declares at slot 7.
int _count(Arena arena, ComPtr self, int slot, String owner) =>
    _getInt(arena, self, slot, '$owner::get_Count');

void _putInt(Arena arena, ComPtr self, int slot, int value, String operation) {
  checkHResult(
    vtableSlot<Int32 Function(ComPtr, Int32)>(
      self,
      slot,
    ).asFunction<int Function(ComPtr, int)>()(self, value),
    operation,
  );
}

/// `VARIANT_TRUE`. **Not `1`** — the type is a 16-bit integer whose true is all
/// bits set, and the getters return exactly this.
const int _variantTrue = -1;

/// `VARIANT_FALSE`.
const int _variantFalse = 0;

// Identifiers, pasted from `taskschd.h` unaltered so they can be compared to it
// by eye. `com_test.dart` checks that this package parses each of them into the
// same bytes Windows' own `IIDFromString` does.
const String _clsidTaskScheduler = '0f87369f-a4e5-4cfc-bd3e-73e6154572dd';
const String _iidTaskService = '2faba4c7-4da9-4013-9697-20cc3fd40f85';
const String _iidExecAction = '4c3d624d-fd6b-49a3-b9b7-09cb3cd3f047';
const String _iidExecAction2 = 'f2a82542-bda5-4e6b-9143-e2bf4F8987b6';
const String _iidLogonTrigger = '72DADE38-FAE4-4b3e-BAF4-5D009AF02B1C';

// Vtable slot indices, read from the `*Vtbl` structs in `taskschd.h`.
//
// **They are not the order the documentation lists the methods in, and they are
// not the order a caller uses them in.** Every one of these interfaces derives
// from `IDispatch`, so slots 0–2 are `IUnknown` and 3–6 are `IDispatch`; the
// interface's own methods begin at 7, in declaration order. `Connect` is the
// clearest trap: it is the first method any caller invokes and the last one
// declared, so it sits at slot 10, behind `GetFolder` and `NewTask`.
//
// A wrong index here compiles, links and calls — through a valid function
// pointer, into the wrong function. No test catches that on its own, which is
// why these come from the header rather than from prose.
const int _serviceGetFolder = 7;
const int _serviceNewTask = 9;
const int _serviceConnect = 10;

const int _folderCreateFolder = 11;
const int _folderDeleteFolder = 12;
const int _folderGetTask = 13;
const int _folderDeleteTask = 15;
const int _folderRegisterTaskDefinition = 17;

const int _definitionGetTriggers = 9;
const int _definitionGetSettings = 11;
const int _definitionGetPrincipal = 15;
const int _definitionGetActions = 17;

// **Not the same slot as `IActionCollection::Create`, which is 12.** The two
// collections read as siblings and are not: `ITriggerCollection` has no
// `XmlText` property pair, so everything after `get__NewEnum` sits two slots
// earlier. Taking this by analogy would call `get__NewEnum` instead — through a
// valid pointer, with the wrong signature.
const int _triggersCreate = 10;

const int _triggersGetCount = 7;
const int _triggersGetItem = 8;

const int _triggerGetType = 7;
const int _triggerGetEnabled = 18;

const int _logonTriggerPutDelay = 21;
const int _logonTriggerPutUserId = 23;

const int _principalPutUserId = 12;
const int _principalPutLogonType = 14;
const int _principalPutRunLevel = 18;

const int _settingsPutStopIfGoingOnBatteries = 16;
const int _settingsPutDisallowStartIfOnBatteries = 18;
const int _settingsPutStartWhenAvailable = 22;
const int _settingsPutExecutionTimeLimit = 28;
const int _settingsPutEnabled = 30;

const int _actionsGetCount = 7;
const int _actionsGetItem = 8;
const int _actionsCreate = 12;

const int _execActionGetPath = 10;
const int _execActionPutPath = 11;
const int _execActionGetArguments = 12;
const int _execActionPutArguments = 13;

/// `IExecAction2::put_HideAppWindow`, the property this whole mechanism exists
/// for. Declared in `taskschd.h`, absent from the documentation.
const int _execAction2PutHideAppWindow = 17;

const int _registeredTaskGetEnabled = 10;
const int _registeredTaskGetDefinition = 19;

/// `TASK_ACTION_EXEC`.
const int _taskActionExec = 0;

/// `TASK_CREATE_OR_UPDATE`.
const int _taskCreateOrUpdate = 6;

/// `TASK_LOGON_INTERACTIVE_TOKEN` — run as whoever is logged on, using the
/// token they already have. The only logon type that needs no password and no
/// privilege.
const int _taskLogonInteractiveToken = 3;

/// `TASK_TRIGGER_LOGON`.
const int _taskTriggerLogon = 9;

/// `TASK_RUNLEVEL_LUA` — the user's ordinary token, not the elevated one.
const int _taskRunLevelLua = 0;
