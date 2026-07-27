/// The two ways Windows can be told to start a program at login.
///
/// They trade off differently and neither dominates, which is why the choice
/// belongs to the calling application rather than to this package, and why
/// there is no automatic fallback between them. See
/// `docs/adr/0001-windows-autostart-mechanisms.md` for the measurements behind
/// the difference.
enum WindowsAutostartMechanism {
  /// The registry `Run` key: one value under the current user, no elevation, no
  /// external service.
  ///
  /// Simple and universally understood — it is the list Task Manager's "Startup
  /// apps" tab shows, so a user can see and switch off the entry in the place
  /// they expect.
  ///
  /// **It cannot hide the console window.** A program built with
  /// `dart compile exe` is a console-subsystem executable, and Windows shows a
  /// console window for one at every login. Nothing the program does at runtime
  /// can suppress it.
  runKey,

  /// A scheduled task in a folder this package owns.
  ///
  /// The only unelevated mechanism that can start a console-subsystem program
  /// **with no visible window**, and the only one that can delay the start so
  /// the program does not compete with the rest of the login sequence.
  ///
  /// The costs: the registration is a scheduled task rather than a startup
  /// entry, so it appears in Task Scheduler rather than in Task Manager's
  /// "Startup apps" tab, and the task tree is machine-wide where the `Run` key
  /// is per-user.
  taskScheduler,
}

/// Windows-only settings, read by the Windows backend and ignored elsewhere.
///
/// Kept out of `AutostartConfig` deliberately: that describes *what* to
/// register and is the same on every platform, while these describe *how*
/// Windows should do it and have no meaning on macOS.
class WindowsAutostartOptions {
  /// Creates the Windows settings.
  ///
  /// Throws [ArgumentError] when [startupDelay] is negative, and when it is
  /// given for [WindowsAutostartMechanism.runKey] — the `Run` key has no way to
  /// express a delay, and silently dropping the value would be worse than
  /// refusing it.
  const WindowsAutostartOptions({
    this.mechanism = WindowsAutostartMechanism.runKey,
    this.hideWindow,
    this.startupDelay,
  });

  /// Which mechanism registers the program.
  ///
  /// Defaults to [WindowsAutostartMechanism.runKey]: it is the simpler of the
  /// two and costs nothing, so a caller who has not thought about the console
  /// window gets the mechanism with the fewest moving parts.
  final WindowsAutostartMechanism mechanism;

  /// Whether the launched program's console window is hidden, or `null` to
  /// take whatever the chosen mechanism can do.
  ///
  /// Only [WindowsAutostartMechanism.taskScheduler] can hide it, and doing so
  /// is the reason to choose that mechanism — so the default, `null`, hides the
  /// window there and accepts the visible one under
  /// [WindowsAutostartMechanism.runKey], which has no way to suppress it.
  ///
  /// Asking for `true` under [WindowsAutostartMechanism.runKey] is refused
  /// rather than ignored. That combination is the single most consequential
  /// thing this package could drop silently: the caller would be told autostart
  /// is configured and get a black console window at every login, which is the
  /// defect the other mechanism exists to fix.
  final bool? hideWindow;

  /// Whether the window should be hidden, resolved for [mechanism].
  bool get hideWindowOrDefault =>
      hideWindow ?? (mechanism == WindowsAutostartMechanism.taskScheduler);

  /// How long after logon to wait before starting, or `null` to start at once.
  ///
  /// Only [WindowsAutostartMechanism.taskScheduler] can express this.
  final Duration? startupDelay;

  /// Validates the combination, throwing [ArgumentError] when it cannot be
  /// honoured.
  ///
  /// Called by the backend factory rather than by the constructor so that these
  /// stay `const`-constructible; the check runs before anything is written.
  void validate() {
    if (mechanism == WindowsAutostartMechanism.runKey && hideWindow == true) {
      throw ArgumentError.value(
        hideWindow,
        'hideWindow',
        'the registry Run key cannot hide a console window — use '
            'WindowsAutostartMechanism.taskScheduler',
      );
    }

    final delay = startupDelay;
    if (delay == null) return;

    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'startupDelay', 'must not be negative');
    }
    if (delay != Duration.zero && delay < const Duration(seconds: 1)) {
      throw ArgumentError.value(
        delay,
        'startupDelay',
        'must be zero or at least one second — a scheduled task stores its '
            'delay with no unit smaller than a second',
      );
    }
    if (mechanism == WindowsAutostartMechanism.runKey) {
      throw ArgumentError.value(
        delay,
        'startupDelay',
        'the registry Run key cannot delay a startup entry — use '
            'WindowsAutostartMechanism.taskScheduler',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is WindowsAutostartOptions &&
      other.mechanism == mechanism &&
      other.hideWindow == hideWindow &&
      other.startupDelay == startupDelay;

  @override
  int get hashCode => Object.hash(mechanism, hideWindow, startupDelay);

  @override
  String toString() =>
      'WindowsAutostartOptions(mechanism: $mechanism, '
      'hideWindow: $hideWindow, startupDelay: $startupDelay)';
}
