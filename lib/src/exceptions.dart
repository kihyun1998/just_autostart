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
/// Windows and macOS are the platforms this package targets. Windows is
/// implemented; macOS is not yet, so it raises this alongside every platform
/// that is out of scope.
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

/// Thrown when an operating system call fails.
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
