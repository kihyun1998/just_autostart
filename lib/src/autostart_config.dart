/// Everything a backend needs to register a program at login.
///
/// [executablePath] is required and is never inferred. `Platform.resolvedExecutable`
/// looks like the obvious default, but under `dart pub global activate` it
/// points at the Dart runtime rather than at the caller's tool — registering
/// the wrong binary silently is worse than asking for one argument.
class AutostartConfig {
  /// Creates a configuration, rejecting values no backend could act on.
  ///
  /// Throws [ArgumentError] when a value is blank, or when [label] contains a
  /// path separator.
  AutostartConfig({
    required this.appName,
    required this.label,
    required this.executablePath,
    List<String> args = const [],
  }) : args = List.unmodifiable(args) {
    _requirePresent(appName, 'appName');
    _requirePresent(label, 'label');
    _requirePresent(executablePath, 'executablePath');

    // On macOS the label becomes a file name inside the LaunchAgents
    // directory. A separator would let a caller write outside the directory the
    // backend targets, so it is rejected here rather than in one backend.
    if (label.contains('/') || label.contains(r'\')) {
      throw ArgumentError.value(
        label,
        'label',
        'must not contain a path separator',
      );
    }
  }

  /// The human-readable name the user sees.
  ///
  /// On Windows this is the registry value name and the scheduled task name,
  /// so it is what appears in Task Manager's list of startup apps.
  final String appName;

  /// A reverse-DNS identifier that is unique to this program.
  ///
  /// On macOS this is the launchd job label and the name of the property list
  /// file, which must match each other — hence one value rather than two.
  final String label;

  /// The absolute path of the executable to launch.
  final String executablePath;

  /// Arguments passed to the executable at login.
  ///
  /// Unmodifiable, so a configuration cannot be changed out from under a
  /// backend that has already read it.
  final List<String> args;

  static void _requirePresent(String value, String name) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, 'must not be blank');
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AutostartConfig &&
        other.appName == appName &&
        other.label == label &&
        other.executablePath == executablePath &&
        _sameArgs(other.args, args);
  }

  @override
  int get hashCode =>
      Object.hash(appName, label, executablePath, Object.hashAll(args));

  @override
  String toString() =>
      'AutostartConfig(appName: $appName, label: $label, '
      'executablePath: $executablePath, args: $args)';

  static bool _sameArgs(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
