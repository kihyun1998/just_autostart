import 'list_equals.dart';

/// macOS-only settings, read by the macOS backend and ignored elsewhere.
///
/// Kept out of `AutostartConfig` for the same reason as the Windows settings:
/// that describes *what* to register and is the same on every platform, while
/// these describe *how* launchd should run it and have no meaning on Windows.
///
/// Every value here is optional, and an unset one is **absent from the written
/// plist** rather than written with a default. That is deliberate: launchd has
/// its own defaults, and writing our idea of them would freeze today's
/// behaviour into every agent this package registers.
class MacosAutostartOptions {
  /// Creates the macOS settings.
  ///
  /// Throws [ArgumentError] from [validate] when a supplied path is blank or
  /// relative, or a variable name is unusable — each of those produces a plist
  /// launchd accepts and then does something other than what the caller meant,
  /// which is worse than refusing it.
  const MacosAutostartOptions({
    this.keepAlive,
    this.standardOutPath,
    this.standardErrorPath,
    this.workingDirectory,
    this.environment = const {},
    this.activateImmediately = false,
  });

  /// Whether `enable()` also starts the agent in the **current** session,
  /// instead of leaving it to begin at the next login.
  ///
  /// A user who has just switched an app's autostart toggle on expects it to
  /// take effect now. Off by default, because writing the plist is already
  /// enough for the next login and the extra step touches the running session.
  ///
  /// **Failing to start it now does not fail `enable()`.** The registration has
  /// been written and the agent will start at the next login regardless, so
  /// raising an exception would tell the caller something false. Ask
  /// `MacosAutostartBackend.isRunningNow()` for whether the agent actually
  /// reached the current session.
  final bool activateImmediately;

  /// Whether launchd restarts the program when it exits.
  ///
  /// `null`, the default, leaves the key out and launchd does not restart it —
  /// the right answer for a program that does its work and exits. Set it for a
  /// long-lived daemon, where an unnoticed crash would otherwise end the
  /// service silently until the next login.
  final bool? keepAlive;

  /// A file to receive the program's standard output.
  ///
  /// A program started at login has no terminal attached, so without this its
  /// output goes nowhere and a failure to start leaves no trace. The path is
  /// the calling application's to choose — where a tool's logs belong is its
  /// own business, not this package's.
  final String? standardOutPath;

  /// A file to receive the program's standard error.
  final String? standardErrorPath;

  /// The directory launchd changes to before running the program.
  ///
  /// Without it the working directory is not the one an interactive run would
  /// have, which is the usual reason a program behaves differently at login
  /// than it does by hand.
  final String? workingDirectory;

  /// Environment variables set for the launched process.
  ///
  /// A login agent does **not** inherit the environment of a login shell, so a
  /// program that reads `PATH` or a configuration variable needs it stated
  /// here.
  final Map<String, String> environment;

  /// Validates the values, throwing [ArgumentError] when one cannot be honoured.
  ///
  /// Called by the backend factory rather than by the constructor so these stay
  /// `const`-constructible; the check runs before anything is written.
  void validate() {
    _requireAbsolutePath(standardOutPath, 'standardOutPath');
    _requireAbsolutePath(standardErrorPath, 'standardErrorPath');
    _requireAbsolutePath(workingDirectory, 'workingDirectory');

    for (final name in environment.keys) {
      if (name.trim().isEmpty) {
        throw ArgumentError.value(
          name,
          'environment',
          'an environment variable name must not be blank',
        );
      }
      // `=` terminates a name in every environment this could reach, so a name
      // containing one would silently become a different variable.
      if (name.contains('=')) {
        throw ArgumentError.value(
          name,
          'environment',
          'an environment variable name must not contain "="',
        );
      }
    }
  }

  /// Requires a path that launchd will resolve the way the caller means.
  ///
  /// Blank is refused for the obvious reason. **Relative is refused because
  /// launchd resolves it against the wrong thing**: `WorkingDirectory` is a
  /// `chdir(2)` and the log paths are opened by launchd itself, in a process
  /// whose working directory is not the calling application's. A relative path
  /// is therefore accepted by launchd and quietly points somewhere the caller
  /// cannot predict — the silent-drop failure this package refuses everywhere
  /// else, rather than an impossible value.
  static void _requireAbsolutePath(String? value, String name) {
    if (value == null) return;
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, 'must not be blank');
    }
    if (!value.startsWith('/')) {
      throw ArgumentError.value(
        value,
        name,
        'must be an absolute path — launchd resolves a relative one against '
        'its own working directory, not yours',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MacosAutostartOptions &&
      other.keepAlive == keepAlive &&
      other.standardOutPath == standardOutPath &&
      other.standardErrorPath == standardErrorPath &&
      other.workingDirectory == workingDirectory &&
      other.activateImmediately == activateImmediately &&
      mapEquals(other.environment, environment);

  @override
  int get hashCode => Object.hash(
    keepAlive,
    standardOutPath,
    standardErrorPath,
    workingDirectory,
    activateImmediately,
    Object.hashAllUnordered(environment.keys),
  );

  @override
  String toString() =>
      'MacosAutostartOptions(keepAlive: $keepAlive, '
      'standardOutPath: $standardOutPath, '
      'standardErrorPath: $standardErrorPath, '
      'workingDirectory: $workingDirectory, environment: $environment, '
      'activateImmediately: $activateImmediately)';
}
