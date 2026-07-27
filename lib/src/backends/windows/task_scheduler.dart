import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
import 'com.dart';

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

  /// Registers a task named [name] that runs [executablePath].
  ///
  /// The task has **no trigger**, so it is registered and inert: nothing will
  /// ever launch it. Triggers, window hiding and the rest of the definition
  /// arrive with the backend that uses this.
  ///
  /// It also carries **no settings**, which is not the same as carrying
  /// harmless ones. Task Scheduler's defaults include
  /// `DisallowStartIfOnBatteries` and `StopIfGoingOnBatteries`, both true — so
  /// a task registered exactly like this and given a logon trigger would
  /// silently never run on an unplugged laptop. Whatever adds the trigger must
  /// also set `ITaskSettings`.
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
  void createTask(String name, {required String executablePath}) {
    _withFolder(create: true, (arena, service, folder) {
      final definition = _newTask(arena, service);
      _setExecAction(arena, definition, executablePath);

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
  bool taskExists(String name) {
    return _withFolder(create: false, (arena, service, folder) {
      if (folder == nullptr) return false;
      return _getTask(arena, folder, name) != null;
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

  /// Gives [definition] a single action that runs [executablePath].
  ///
  /// A definition with no action cannot be registered — Task Scheduler rejects
  /// it — which is why this exists in a ticket that is otherwise only about
  /// plumbing.
  void _setExecAction(Arena arena, ComPtr definition, String executablePath) {
    final actions = arena<ComPtr>();
    checkHResult(
      vtableSlot<Int32 Function(ComPtr, Pointer<ComPtr>)>(
        definition,
        _definitionGetActions,
      ).asFunction<int Function(ComPtr, Pointer<ComPtr>)>()(
        definition,
        actions,
      ),
      'ITaskDefinition::get_Actions',
    );
    final actionCollection = ownInterface(arena, actions.value);

    final created = arena<ComPtr>();
    checkHResult(
      vtableSlot<Int32 Function(ComPtr, Int32, Pointer<ComPtr>)>(
        actionCollection,
        _actionsCreate,
      ).asFunction<int Function(ComPtr, int, Pointer<ComPtr>)>()(
        actionCollection,
        _taskActionExec,
        created,
      ),
      'IActionCollection::Create',
    );
    final action = ownInterface(arena, created.value);

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

    checkHResult(
      vtableSlot<Int32 Function(ComPtr, Pointer<Utf16>)>(
        execAction,
        _execActionPutPath,
      ).asFunction<int Function(ComPtr, Pointer<Utf16>)>()(
        execAction,
        allocateBstr(arena, executablePath),
      ),
      'IExecAction::put_Path',
    );
  }
}

// Identifiers, pasted from `taskschd.h` unaltered so they can be compared to it
// by eye. `com_test.dart` checks that this package parses each of them into the
// same bytes Windows' own `IIDFromString` does.
const String _clsidTaskScheduler = '0f87369f-a4e5-4cfc-bd3e-73e6154572dd';
const String _iidTaskService = '2faba4c7-4da9-4013-9697-20cc3fd40f85';
const String _iidExecAction = '4c3d624d-fd6b-49a3-b9b7-09cb3cd3f047';

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

const int _definitionGetActions = 17;

const int _actionsCreate = 12;

const int _execActionPutPath = 11;

/// `TASK_ACTION_EXEC`.
const int _taskActionExec = 0;

/// `TASK_CREATE_OR_UPDATE`.
const int _taskCreateOrUpdate = 6;

/// `TASK_LOGON_INTERACTIVE_TOKEN` — run as whoever is logged on, using the
/// token they already have. The only logon type that needs no password and no
/// privilege.
const int _taskLogonInteractiveToken = 3;
