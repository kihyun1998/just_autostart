import 'dart:io';

import '../../autostart_backend.dart';
import '../../autostart_config.dart';
import '../../exceptions.dart';
import '../../list_equals.dart';
import '../../macos_options.dart';
import 'launch_agent_plist.dart';
import 'launchctl.dart';

/// `ENOENT` — nothing at the path resolves to a file.
///
/// Measured on macOS 14.5 (#22) for the three shapes that reach this package:
/// a missing file, a dangling symlink, and a missing directory component all
/// report `2`. The neighbouring failures are distinct and must not be folded in
/// with it: an unreadable file is `13`, a directory read as a file is `21`, and
/// a symlink loop is `62`.
const int _pathDoesNotResolve = 2;

/// Registers a program at login through a launchd **user agent**.
///
/// The registration is a property list file in the user's `LaunchAgents`
/// directory, written with `dart:io`. launchd scans that directory at login, so
/// writing the file is enough to start the program at the next login — no
/// `launchctl` call, no FFI, and no dependency. The mechanism is a LaunchAgent
/// rather than `SMAppService` because a `dart compile exe` output is a bare
/// Mach-O with no `.app` bundle for that API to register.
///
/// The launchd job label doubles as the file name (`<label>.plist`), so the two
/// always agree. [AutostartConfig] rejects a label containing a path separator,
/// which is what stops the file name from escaping this directory.
final class MacosAutostartBackend implements AutostartBackend {
  /// Creates a backend for [config].
  ///
  /// [launchAgentsDirectory] is the single seam: tests point it at a temporary
  /// directory and the real file-writing code runs against it. It defaults to
  /// `~/Library/LaunchAgents`, resolved when an operation runs rather than at
  /// construction, so a caller can build the backend before deciding to use it.
  const MacosAutostartBackend({
    required this.config,
    Directory? launchAgentsDirectory,
    this.launchctl = const SystemLaunchctl(),
    this.options = const MacosAutostartOptions(),
  }) : _launchAgentsDirectory = launchAgentsDirectory;

  /// What to register.
  final AutostartConfig config;

  /// How launchd should run it — the optional agent settings.
  ///
  /// Every unset value is left out of the plist entirely, so the default
  /// instance produces the minimal agent.
  final MacosAutostartOptions options;

  /// Reads and clears the user's launchd disable overrides — the second store,
  /// separate from the plist, that records a Login Items veto.
  final Launchctl launchctl;

  final Directory? _launchAgentsDirectory;

  /// The directory the agent's plist is written into.
  ///
  /// The injected value in a test, or `~/Library/LaunchAgents` in production.
  Directory get launchAgentsDirectory =>
      _launchAgentsDirectory ?? _defaultLaunchAgentsDirectory();

  File get _plistFile =>
      File('${launchAgentsDirectory.path}/${config.label}.plist');

  /// Writes the launch agent so the executable starts at login.
  ///
  /// Idempotent: the file is written whole every time, so enabling something
  /// already enabled leaves exactly one well-formed agent. Rejects an executable
  /// that does not exist, because the alternative is a registration that looks
  /// successful and silently launches nothing at the user's next login.
  ///
  /// It also **clears the user's Login-Items veto** — the launchd disable
  /// override that lives outside the plist, recording that the user switched the
  /// agent off in System Settings. Overriding that veto matches the package's
  /// boundary rule (the calling application is expected to have asked its user
  /// first) and keeps the platforms symmetric with Windows, which rewrites its
  /// approval byte on every `enable()`. Clearing it via `launchctl enable` was
  /// measured to succeed unprivileged on macOS 14.5 (see `docs/agents/theflow.md`).
  ///
  /// If the veto still stands after the attempt — the clear failed *and* the
  /// override is confirmed present — `enable()` throws rather than returning a
  /// success that a following `isEnabled()` would contradict. A launchctl that
  /// cannot be read at all degrades to "no veto known", the same as
  /// [isEnabled], so the two never disagree.
  @override
  Future<void> enable() async {
    final executable = File(config.executablePath);
    if (!executable.existsSync()) {
      throw ExecutableNotFoundException(config.executablePath);
    }
    // Existence is not launchability: a file with no execute bit passes the
    // check above but fails execvp at login. 0x49 is the owner/group/other
    // execute bits; none set means the file cannot run for anyone.
    if (executable.statSync().mode & 0x49 == 0) {
      throw ExecutablePermissionException(config.executablePath);
    }

    final xml = generateLaunchAgentPlist(
      label: config.label,
      executablePath: config.executablePath,
      args: config.args,
      keepAlive: options.keepAlive,
      standardOutPath: options.standardOutPath,
      standardErrorPath: options.standardErrorPath,
      workingDirectory: options.workingDirectory,
      environment: options.environment,
    );

    try {
      launchAgentsDirectory.createSync(recursive: true);
      _writeRegistration(xml);
    } on FileSystemException catch (error) {
      throw AutostartOsException(
        operation: 'write the LaunchAgent plist',
        detail: error.message,
        errorCode: error.osError?.errorCode,
      );
    }

    launchctl.clearOverride(config.label);
    if (_isVetoedByUser()) {
      throw AutostartOsException(
        operation: 'clear the Login Items veto for "${config.label}"',
        detail:
            'the user switched this agent off in System Settings and the veto '
            'could not be cleared',
      );
    }

    if (options.activateImmediately) _activate();
  }

  /// Writes [xml] into this application's slot, replacing whatever is there.
  ///
  /// **It writes a temporary file beside the slot and renames it over, rather
  /// than writing to the slot directly.** The slot is a name in a shared
  /// namespace, and what occupies it is not necessarily a regular file this
  /// package put there. `writeAsStringSync` *follows* whatever it finds, so
  /// writing directly sends this package's bytes wherever that points —
  /// measured on macOS 14.5 (#23) in three shapes: a symlink to a file has its
  /// **target's content replaced**, a **dangling** symlink has its target
  /// **created**, and a hard link changes the other name's content. All three
  /// write outside the one directory this package's identity scopes it to.
  ///
  /// `rename(2)` is the operation that does not follow: *"If the final
  /// component of old is a symbolic link, the symbolic link is renamed, not the
  /// file or directory to which it points."* So the link is replaced and its
  /// target is left exactly as it was. It also *"guarantees that an instance of
  /// new will always exist, even if the system should crash in the middle"* —
  /// so there is no moment where the slot holds a half-written plist, which
  /// `disable()` could never clean up (its guard cannot parse a truncated file,
  /// so it would correctly refuse to remove it).
  ///
  /// **The alternative that looks equivalent and is not.** Removing the slot
  /// first and then writing — which is what Homebrew does for this same
  /// directory (`services/cli.rb:432-434`, `rm` then `cp`) — cannot be
  /// expressed in Dart. `File.deleteSync` resolves the path, so it *fails* on
  /// exactly the states that matter and leaves them in place: errno 2 for a
  /// dangling symlink and a symlink loop, errno 21 for a symlink to a
  /// directory. The guard would skip, the write would follow the link, and the
  /// defect would survive behind code that looks like it handles the case.
  ///
  /// Note this is **not** the rename that `docs/adr/0002` rejects. That one
  /// renames a registration *away* to a private name before verifying it, on
  /// the removal path, and is refused because it can clobber a file that
  /// arrived meanwhile and can strand a third party's plist under a name
  /// launchd will not load. This renames a file *we just wrote* onto our own
  /// slot: the source is a name only this process knows, and a crash leaves the
  /// previous registration intact.
  ///
  /// The permissions are set on the temporary file, so the plist is never
  /// visible in `LaunchAgents` carrying the group/other write bits launchd
  /// silently refuses (#13).
  ///
  /// **One behaviour this changes, and why it is not worth avoiding.** Writing
  /// needs the *directory* to be writable, where writing through an existing
  /// file needed only the file. So a read-only `LaunchAgents` holding a
  /// writable plist used to accept `enable()` and now raises
  /// `AutostartOsException` code 13 (measured, #23). That setup was never one
  /// this package could serve: `disable()` needs the same directory write to
  /// unlink, and `enable()` already called `createSync` on it. Failing at the
  /// write is the honest version of a state that could not be maintained
  /// anyway.
  void _writeRegistration(String xml) {
    // Dot-prefixed and not ending in `.plist`, so a temp stranded by a crash
    // is not a shape launchd would try to load. `launchd.plist(5)` says only
    // that agents are *expected* to end in `.plist`, which is an expectation
    // rather than a documented filter, so the name avoids the question instead
    // of relying on the answer.
    final temp = File(
      '${launchAgentsDirectory.path}/.${config.label}.$pid.tmp',
    );
    try {
      temp.writeAsStringSync(xml);
      // The temp is a *new* file, so it takes the process umask rather than the
      // mode of the registration it replaces. Writing to the slot directly used
      // to preserve that mode for free; carrying it across is what keeps the
      // recorded promise that a caller who made their agent `0600` keeps it
      // private, which is otherwise the one thing this shape would lose.
      _restrictPermissions(temp, inheriting: _existingSlotMode());
      temp.renameSync(_plistFile.path);
    } catch (_) {
      // A failed write must not leave litter in a directory this package does
      // not own outright. Best-effort: the original failure is what the caller
      // needs, so a cleanup that also fails must not replace it.
      try {
        if (temp.existsSync()) temp.deleteSync();
      } on FileSystemException {
        // Nothing further to do; the rethrow below carries the real failure.
      }
      rethrow;
    }
  }

  /// Clears the group and other **write** bits on the written agent.
  ///
  /// launchd refuses a job definition that anyone but its owner can write, and
  /// the refusal is **silent**: the file stays in `LaunchAgents`, parses, and
  /// nothing launches. `File.writeAsStringSync` takes whatever the process
  /// umask gives it — `0644` under the usual `0022`, but `0666` under `umask 0`
  /// and `0664` under `umask 002`, both of which occur in build systems and
  /// containers. Measured on macOS 14.5: the same plist loads at `0644` and
  /// fails with `Bootstrap failed: 5: Input/output error` at `0666`.
  ///
  /// It clears those two bits rather than forcing `0644`, so a caller who
  /// deliberately made the agent `0600` keeps it private.
  ///
  /// `dart:io` has no `chmod`, so this shells out like the `launchctl` calls do
  /// — still no native code. A failure to restrict is raised rather than
  /// ignored: the registration would otherwise be one launchd will not load.
  ///
  /// [inheriting] is the mode of the registration being replaced, when there is
  /// one. It is applied *with the two write bits already cleared*, in the same
  /// single `chmod`, so the deliberate-`0600` case survives being written
  /// through a temporary file — see [_writeRegistration].
  void _restrictPermissions(File file, {int? inheriting}) {
    // 0x10 is group-write and 0x2 other-write, the pair [_isWorldWritable]
    // reads back.
    final argument = inheriting == null
        ? 'go-w'
        : (inheriting & ~0x12).toRadixString(8).padLeft(3, '0');

    final ProcessResult result;
    try {
      result = Process.runSync('chmod', [argument, file.path]);
    } on ProcessException catch (error) {
      throw AutostartOsException(
        operation: 'restrict permissions on the LaunchAgent plist',
        detail: error.message,
      );
    }

    if (result.exitCode != 0) {
      throw AutostartOsException(
        operation: 'restrict permissions on the LaunchAgent plist',
        detail: '${result.stderr}'.trim(),
        errorCode: result.exitCode,
      );
    }
  }

  /// The permission bits of the registration currently in the slot, or `null`
  /// when the slot does not already hold a regular file.
  ///
  /// Deliberately does **not** follow a symlink. A link is about to be
  /// replaced rather than written through, and the mode that matters is the
  /// registration's own — a symlink's own bits are meaningless to launchd, and
  /// its *target* is somebody else's file whose mode this package has no
  /// business propagating into `LaunchAgents`.
  int? _existingSlotMode() {
    final path = _plistFile.path;
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    return _plistFile.statSync().mode & 0xFFF;
  }

  /// Whether [file] is writable by group or other, which makes launchd refuse
  /// it — see [_restrictPermissions].
  ///
  /// `0x10` is the group-write bit and `0x2` the other-write bit.
  static bool _isWorldWritable(File file) {
    final mode = file.statSync().mode;
    return mode & 0x10 != 0 || mode & 0x2 != 0;
  }

  /// Starts the agent in the current session, replacing a job already loaded
  /// under this label.
  ///
  /// The bootout comes first for two measured reasons: `launchctl bootstrap`
  /// **fails** when the label is already loaded, which is the ordinary
  /// repeat-`enable()` path; and a job loaded from an earlier `enable()` keeps
  /// running the *old* configuration, so re-loading is what makes a changed
  /// executable or argument list take effect now.
  ///
  /// Nothing here throws. Both commands report failure in situations that are
  /// not failures at all (nothing was loaded; the session is not a GUI one),
  /// and the registration this method follows has already succeeded — the agent
  /// starts at the next login whatever happens here. [isRunningNow] is how a
  /// caller learns the outcome.
  void _activate() {
    launchctl
      ..bootout(config.label)
      ..bootstrap(_plistFile.path);
  }

  /// Whether the agent is loaded into the **current** login session.
  ///
  /// Distinct from [isEnabled], which answers "will it start at the next
  /// login". A caller that asked for [MacosAutostartOptions.activateImmediately]
  /// uses this to find out whether starting it now actually worked — the outcome
  /// `enable()` deliberately does not throw for.
  ///
  /// What it reports precisely is that launchd **has the job**, which is the
  /// answer to "did activation take". It is not a liveness check on the
  /// process: a program that has already run and exited leaves its job loaded,
  /// so this stays true for a short-lived program that is no longer executing.
  /// For the long-running daemons this option exists to serve the two coincide;
  /// where they do not, the process's own health is the application's to
  /// observe, not something launchd's registration can tell it.
  ///
  /// Read from launchd rather than remembered from the attempt, for the same
  /// reason [isEnabled] reads the operating system rather than a stored
  /// preference: the session can change without this package seeing it.
  Future<bool> isRunningNow() async => launchctl.isLoaded(config.label);

  /// Removes this application's launch agent, if one is present.
  ///
  /// Idempotent: removing what was never written is not an error, and neither
  /// is losing the race to remove it — a file that goes away mid-operation
  /// leaves nothing to report.
  ///
  /// The `LaunchAgents` directory is a **shared namespace**, and — critically —
  /// launchd identifies a job by the `Label` **inside** the file, not by the
  /// file name. A third party's plist can legally sit at `<our-label>.plist`
  /// while belonging to a different agent, so deleting on the file name alone
  /// would destroy their registration with no way back (a sacred path). The
  /// guard is that the file's internal `Label` must equal ours before it is
  /// removed. A file we cannot read as ours — a foreign label, a plist too
  /// corrupt to parse, or something that is not a regular file at all — is left
  /// in place rather than deleted or raised.
  ///
  /// Matching the label rather than the path means a registration whose binary
  /// *moved* is still ours to remove — it is the same launchd job — which is the
  /// registration `enable()` would otherwise leave running.
  ///
  /// **The guard is established twice, and the second time is the load-bearing
  /// one.** `deleteSync` acts on the *path*; the check acts on the *bytes*. So
  /// what matters is not that a check happened but how much can run between the
  /// last one and the unlink — and a `launchctl bootout` has to run in there
  /// (see below). Measured on macOS 14.5 with `dart compile exe`, one operation
  /// per fresh process, which is the shape a consumer actually runs (#22):
  ///
  /// | inside the window | before | after |
  /// | --- | --- | --- |
  /// | first `parseLaunchAgentPlist` | 235 µs | — |
  /// | `id -u`, resolving `gui/<uid>` for the first spawn | 1,533 µs | — |
  /// | `launchctl bootout` | 1,626 µs | — |
  /// | comparing the second read against the first | — | < 1 µs |
  /// | `deleteSync` | 51 µs | 51 µs |
  /// | **total** | **~3,445 µs** | **49 µs** |
  ///
  /// The *before* total is a sum of separately measured parts, not one
  /// stopwatch — say which, or it is the labelling error `lessons.md` #28 is
  /// about. Cross-checked against a whole cold `disable()`, which lands at
  /// 3,247 µs (median of 15, spread 3.0–5.5 ms), so the sum is right to about
  /// its own noise and no further. The *after* figure is one stopwatch, over
  /// the two operations named.
  ///
  /// The `bootout` row is a label that was **not** loaded, which is the cheap
  /// case and so the conservative one to quote. Booting out a genuinely loaded
  /// agent was measured separately at 1,300 µs — if anything cheaper, so the
  /// total is not understated by it.
  ///
  /// 56 µs in the case where the bytes changed and the guard re-parses, on the
  /// 533-byte plist this package writes. Without `activateImmediately` the old
  /// window was 286 µs rather than 3,445, since only the two spawns are gated —
  /// the option changed the window's size, never whether there was one.
  ///
  /// The arithmetic is not the argument, though, and an earlier draft of this
  /// ticket leaned on it wrongly in two ways worth recording. It compared the
  /// residual against the ~2,400 µs #16 left on the Windows Task Scheduler
  /// path, as though that were a bar — but `deleteTaskIf`'s own comment says
  /// that figure is *the floor that API allows*, accepted because it could not
  /// be removed, not a width judged safe. And it read the *without*-activation
  /// window as "a few microseconds of Dart file I/O"; it is 286 µs, and the
  /// defect was never scoped to that option.
  ///
  /// **The real reason is that the window's tail was unbounded.** `existsSync`
  /// is not a regular-file test: it is `true` for a FIFO, and
  /// `readAsStringSync` on a FIFO blocks until a writer appears, which may be
  /// never (reproduced, #22). `Process.runSync` has no timeout either. So the
  /// old shape could park an irreversible unlink behind an unbounded wait. What
  /// this method now guarantees is bounded: between the last look and the
  /// unlink there is no subprocess and no call that can block.
  ///
  /// It is still not atomic, and cannot be. An atomic form needs the file's
  /// *identity* rather than its path — open, verify from the handle, unlink
  /// that inode — and every route to that is a syscall Dart does not expose
  /// (`FileStat` carries no inode; `RandomAccessFile` cannot unlink). Closing
  /// it would mean FFI in a backend that deliberately has none.
  ///
  /// **It deliberately leaves the launchd disable override alone**, which is
  /// the one store `enable()` maintains that this does not — so the asymmetry
  /// is recorded rather than left to be rediscovered. Three measured reasons.
  /// `launchctl` has no verb that *removes* a row unprivileged: `enable` sets
  /// it to `enabled`, so "cleaning up" would write a row rather than retire
  /// one. Orphan rows are what the OS itself leaves — `com.apple.Siri.agent`
  /// and `com.apple.FolderActionsDispatcher` sit in the roster on this machine
  /// with no agent on disk. And a row is inert while no registration exists,
  /// because launchd has nothing to apply it to. The product reason is the one
  /// that settles it: `enable()` overriding the user's veto is a recorded
  /// decision made for a reason — the caller asked for autostart *on*.
  /// `disable()` has no such mandate, and clearing a veto on the way out would
  /// quietly make the agent *more* likely to run if anything ever recreated
  /// the plist. Leaving it is the conservative direction as well as the cheap
  /// one.
  @override
  Future<void> disable() async {
    final file = _plistFile;
    if (!file.existsSync()) return;

    final registered = _readRegistration(file);
    if (registered == null || !_isOurLabel(registered)) return;

    // Before the file goes: `launchctl bootout` names a job launchd resolved
    // from this plist, so deleting it first would leave a running job with
    // nothing to unload it by until the next login. The ownership guard above
    // governs this too — booting out a label this application does not own
    // would stop a third party's running agent.
    //
    // Unconditional, rather than gated on `activateImmediately`. That option
    // describes *this backend instance*, not the registration: an application
    // that enabled with it and disables through a default-constructed backend
    // would otherwise delete the file while the job stayed loaded — which is
    // verbatim the harm the ordering above exists to prevent, and it leaves
    // `isEnabled()` false while `isRunningNow()` stays true with no operation
    // able to reconcile them. Booting out a label that is not loaded is a
    // measured no-op (exit 3, "No such process"), so the cost of being right
    // here is one ~1.6 ms spawn on a rare, deliberate operation.
    launchctl.bootout(config.label);

    // Re-establish the guard. The one above is now stale by a process spawn,
    // and it is the *only* thing standing between a third party's plist and an
    // unlink with no undo.
    final current = _readRegistration(file);
    if (current == null) return;
    // Byte-identical to what the check above accepted, so that check still
    // stands and nothing needs parsing inside the window — which is the common
    // case and the one worth making cheap, since the parser is linear in the
    // file's size and re-parsing unconditionally would let whatever is at the
    // path decide how long we sit here.
    //
    // It falls back to a full ownership check rather than refusing on any
    // difference, because a concurrent `enable()` legitimately rewrites this
    // file under the same label; refusing that would leave this application's
    // own registration in place while `disable()` reported success. The
    // residual that buys: a plist swapped for a *large* one still carrying our
    // label is re-parsed inside the window, so the width is content-dependent
    // in exactly the case an adversary would choose. Bounded, unlike the
    // subprocess it replaced, but not constant.
    if (current != registered && !_isOurLabel(current)) return;

    try {
      file.deleteSync();
    } on FileSystemException catch (error) {
      // Someone else removed it between the guard above and here. `disable()`'s
      // contract is that nothing registered means nothing to do, and that has
      // to hold for the racing case too or two concurrent calls make the loser
      // throw.
      //
      // **The suite cannot reach this branch, and deleting it stays green.**
      // Reaching it needs the file to go away inside the ~50 µs between the
      // guard's read and this unlink, and there is deliberately no seam in
      // there — a hook at that point would be the blocking call this whole
      // method exists to keep out of the window. The test that looks like it
      // covers this ("is silent when the plist vanishes during the bootout")
      // does not: it removes the file during `bootout`, so the guard above
      // returns first and this line never runs. Mutation-checked, not assumed
      // — making this errno fatal again left all 87 tests passing. Kept
      // because production can reach what the suite cannot, and recorded here
      // rather than claimed as covered (`lessons.md` #24, #29).
      if (error.osError?.errorCode == _pathDoesNotResolve) return;
      throw AutostartOsException(
        operation: 'remove the LaunchAgent plist',
        detail: error.message,
        errorCode: error.osError?.errorCode,
      );
    }
  }

  /// The contents of the registration at [file], or `null` when there is
  /// nothing there this package may treat as one.
  ///
  /// `null` covers two cases that are both "not a registration of ours to
  /// touch", never "a failure to report":
  ///
  /// - **Not a regular file.** `File.existsSync()` returns `true` for a FIFO
  ///   and for a character device, and `readAsStringSync` on a FIFO blocks
  ///   until a writer appears — for ever, if none does (reproduced on macOS
  ///   14.5, #22). Only a regular file can be a launch agent, so the type is
  ///   checked before anything opens the path. This is what bounds the window
  ///   in [disable]; without it a re-read is a re-hang. [isEnabled] shares this
  ///   reader for the same reason — measured hanging on a FIFO before it did.
  /// - **The path no longer resolves.** Not only "our file was deleted": a
  ///   dangling symlink and a vanished directory component report the same
  ///   `errno`, and all three mean there is nothing to remove.
  ///
  /// Every **other** read failure is raised as a typed [AutostartOsException].
  /// Reporting an unreadable plist at this application's own label as "not
  /// ours" would leave the registration in place while `disable()` returned
  /// success — the swallowed-failure defect this package refuses — and letting
  /// the raw `FileSystemException` escape would break the sealed hierarchy a
  /// caller switches over.
  String? _readRegistration(File file) {
    try {
      if (file.statSync().type != FileSystemEntityType.file) return null;
      return file.readAsStringSync();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == _pathDoesNotResolve) return null;
      throw AutostartOsException(
        operation: 'read the LaunchAgent plist',
        detail: error.message,
        errorCode: error.osError?.errorCode,
      );
    }
  }

  /// Whether [plistXml] is the launch agent this application registered.
  ///
  /// Weaker than [isEnabled]: it asks only "is this our job", by the launchd
  /// identity (the internal `Label`), so a disabled or stale-but-ours agent is
  /// still ours to remove. A document too corrupt to parse is treated as not
  /// ours — the safe direction, since deleting an unreadable stranger's file is
  /// the harm this guard exists to prevent.
  bool _isOurLabel(String plistXml) {
    try {
      return parseLaunchAgentPlist(plistXml).label == config.label;
    } on MalformedRegistrationException {
      return false;
    }
  }

  /// Whether the configured executable will actually launch at login.
  ///
  /// Stricter than "a plist exists". Every condition below governs whether
  /// launchd will start the program, and all of them live inside the file this
  /// reads:
  ///
  /// - the plist exists (a missing one is "not registered" — false, not raised);
  /// - its `ProgramArguments` name the configured executable and arguments, so a
  ///   registration left pointing at an old binary reports false;
  /// - `RunAtLoad` is set, without which launchd loads the job but does not
  ///   start it at login;
  /// - the in-plist `Disabled` key is not set — a second store inside the same
  ///   file that suppresses the job independently of everything above.
  ///
  /// A plist that exists but is corrupt raises [MalformedRegistrationException]:
  /// it sits at this application's own label path, so it is a broken
  /// registration to surface, not a foreign entry to ignore. One that cannot be
  /// *read* raises [AutostartOsException] for the same reason — an unreadable
  /// registration is a state to report, not a quiet `false`, and it must not
  /// escape as a raw `FileSystemException` from outside the sealed hierarchy.
  ///
  /// Something at the path that is not a regular file — a FIFO, a device — is
  /// "not registered", like an absent one. It goes through the same reader as
  /// [disable] so the two cannot disagree about what counts as a registration,
  /// and so this method cannot block on a FIFO the way it used to (#22).
  ///
  /// The final condition is the fourth store, and the only one *outside* the
  /// file: launchd's disable overrides, which record the user switching the
  /// agent off in System Settings. It is read through [launchctl]; a launchctl
  /// that cannot be read degrades to "no veto", so an OS change makes this
  /// slightly too optimistic rather than breaking the API.
  @override
  Future<bool> isEnabled() async {
    final file = _plistFile;
    final content = _readRegistration(file);
    if (content == null) return false;

    final LaunchAgentPlist parsed;
    try {
      parsed = parseLaunchAgentPlist(content);
    } on MalformedRegistrationException catch (error) {
      // The pure parser has no path to name; attach ours so the caller can act
      // on the file the message points at.
      throw MalformedRegistrationException(error.detail, path: file.path);
    }

    // Exact comparison, not case-folded like Windows: a macOS volume can be
    // case-sensitive, and the path being compared is the one the caller passed
    // to both `enable()` and here, so it matches exactly in the normal case.
    if (parsed.executablePath != config.executablePath) return false;
    if (!listEquals(parsed.args, config.args)) return false;
    if (!parsed.runAtLoad) return false;
    if (parsed.disabled) return false;
    // A registration launchd will refuse is not an enabled one. Same class as
    // the two keys above — present, well formed, and inert. This catches a
    // plist written by an earlier version under a permissive umask, or one
    // whose permissions were changed after it was written.
    if (_isWorldWritable(file)) return false;
    if (_isVetoedByUser()) return false;

    return true;
  }

  /// Whether the user has switched this agent off in System Settings.
  ///
  /// Reads launchd's disable overrides through [launchctl]. A read that fails or
  /// returns an unrecognised format is treated as "not vetoed" — the veto has to
  /// be positively present to count, so a launchctl change degrades safely
  /// instead of reporting a working agent as off. `enable()` and [isEnabled] go
  /// through this same predicate, so they cannot disagree about the veto.
  bool _isVetoedByUser() {
    final overrides = launchctl.readDisabledOverrides();
    if (overrides == null) return false;
    return overridesDisableLabel(overrides, config.label);
  }

  static Directory _defaultLaunchAgentsDirectory() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const AutostartOsException(
        operation: 'resolve the LaunchAgents directory',
        detail: 'the HOME environment variable is not set',
      );
    }
    return Directory('$home/Library/LaunchAgents');
  }
}
