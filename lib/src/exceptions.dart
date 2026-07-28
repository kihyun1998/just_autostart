/// The base type for every failure `just_autostart` raises.
///
/// It is sealed, so a caller can switch over the failures exhaustively and the
/// analyzer will point at the switch if a new failure is ever introduced.
///
/// Programmer errors — an empty app name, a blank executable path — are *not*
/// modelled here. Those throw [ArgumentError], following the Dart convention
/// that an [Exception] describes a condition the program could not have known
/// about in advance.
sealed class AutostartException implements Exception {
  /// Creates an autostart failure.
  const AutostartException();

  /// A human-readable description of what went wrong.
  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when autostart is requested on a platform with no backend.
///
/// Raised rather than quietly doing nothing, because a silent no-op lets a
/// developer ship a broken feature without ever seeing a failure.
///
/// Windows and macOS are the platforms this package targets, and both are
/// implemented. Every other operating system raises this.
final class UnsupportedPlatformException extends AutostartException {
  /// Creates a failure naming the [operatingSystem] that has no backend.
  const UnsupportedPlatformException(this.operatingSystem);

  /// The operating system that was asked for, as reported by the platform.
  final String operatingSystem;

  // The message deliberately does not enumerate the supported platforms. That
  // list belongs in documentation, where it cannot drift out of step with which
  // backends are actually wired up.
  @override
  String get message => 'just_autostart has no backend for "$operatingSystem".';
}

/// Thrown when the executable a caller asked to register does not exist.
///
/// This is almost always an installer bug or a path assembled by hand. Catching
/// it at registration time is the point — the alternative is a registration
/// that looks successful and silently fails at the user's next login.
final class ExecutableNotFoundException extends AutostartException {
  /// Creates a failure naming the [executablePath] that could not be found.
  const ExecutableNotFoundException(this.executablePath);

  /// The path that was checked.
  final String executablePath;

  @override
  String get message => 'No executable found at "$executablePath".';
}

/// Thrown when a registration succeeded but an **old one could not be removed**.
///
/// Windows can register a program at login two different ways, and switching
/// between them means removing the registration the other one holds. That
/// cleanup runs as a side effect of `enable()`, so when it fails the caller is
/// in a state no single answer describes: autostart **is** on, and the program
/// may launch **twice**.
///
/// It has its own type because the difference is not decorative. A caller that
/// cannot tell this apart from "enable failed" will reasonably not save the
/// user's preference and will report that autostart could not be turned on —
/// while it is on. [cause] carries the failure underneath.
final class MechanismCleanupException extends AutostartException {
  /// Creates a failure describing an incomplete migration.
  const MechanismCleanupException(this.cause);

  /// What went wrong while removing the other mechanism's registration.
  final AutostartException cause;

  @override
  String get message =>
      'Autostart was registered, but a registration held by the other Windows '
      'mechanism could not be removed, so the program may launch twice: '
      '${cause.message}';
}

/// Thrown when the executable a caller asked to register exists but cannot run.
///
/// A file with no execute permission passes an existence check but fails at
/// launch: launchd's `execvp` returns `EACCES` at the user's next login and
/// nothing starts, with no error the caller ever sees. Distinguished from
/// [ExecutableNotFoundException] because the remedy is different — the path is
/// right, the file is there, and what it needs is its execute bit, not a
/// corrected path.
///
/// The check is "has any execute bit set". Resolving whether the *current user*
/// specifically may execute the file — ownership against owner/group/other
/// bits — is left out: the failure this exists to catch at development time is a
/// binary shipped or copied with no execute permission at all.
final class ExecutablePermissionException extends AutostartException {
  /// Creates a failure naming the [executablePath] that is not executable.
  const ExecutablePermissionException(this.executablePath);

  /// The path that was checked.
  final String executablePath;

  @override
  String get message =>
      'The file at "$executablePath" is not executable; it has no execute '
      'permission bit set.';
}

/// Thrown when a registration this package must read back is corrupt.
///
/// This is distinct from [AutostartOsException] on purpose: no operating system
/// call failed. A file was read, or a stored value fetched, and its *contents*
/// are not something this package could have written — a plist that is not
/// well-formed XML, or one missing the program it must name.
///
/// It matters that this is its own type rather than a silent "not registered".
/// A malformed registration sits at a path derived from the caller's own
/// `label` — unlike a foreign entry in a shared namespace, which is left alone —
/// so a caller can act on it (delete it, warn the user) rather than see autostart
/// silently report off for a file that is theirs and broken.
final class MalformedRegistrationException extends AutostartException {
  /// Creates a failure describing an unreadable registration.
  ///
  /// [detail] says what could not be parsed. [path] is the file it was read
  /// from, where the caller has one — a pure parser has no path to give, so a
  /// backend that read from disk attaches it on the way out, making the failure
  /// self-contained for the "delete it and warn the user" remedy the class is
  /// for.
  const MalformedRegistrationException(this.detail, {this.path});

  /// What was wrong with the stored registration.
  final String detail;

  /// The file the corrupt registration was read from, if known.
  final String? path;

  @override
  String get message => path == null
      ? 'The stored registration is malformed: $detail'
      : 'The stored registration at "$path" is malformed: $detail';
}

/// Thrown when an operating system call fails, or an OS-provided precondition
/// is not met.
///
/// Mostly a failed call — a Win32 function, a `launchctl` invocation — but it
/// also covers a precondition the OS was supposed to provide and did not, such
/// as an unset `HOME` when resolving the macOS `LaunchAgents` directory. Those
/// have no numeric code, so [errorCode] is null and [operation] carries the
/// context.
///
/// Carries enough detail to be actionable in a log: which operation failed,
/// what the platform said, and the numeric code where the platform reports one.
final class AutostartOsException extends AutostartException {
  /// Creates a failure describing an operating system call.
  ///
  /// [operation] names the call that failed — a Win32 function, a `launchctl`
  /// invocation. [detail] is what the platform said. [errorCode] is the
  /// platform's numeric code where it has one.
  const AutostartOsException({
    required this.operation,
    required this.detail,
    this.errorCode,
  });

  /// The operating system call that failed.
  final String operation;

  /// What the platform reported, unedited.
  final String detail;

  /// The platform's numeric error code, where the platform reports one.
  final int? errorCode;

  @override
  String get message => errorCode == null
      ? '$operation failed: $detail'
      : '$operation failed with code $errorCode: $detail';
}
