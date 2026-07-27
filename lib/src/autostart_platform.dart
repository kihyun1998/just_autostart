/// The platforms `just_autostart` distinguishes when choosing a backend.
enum AutostartPlatform {
  /// Windows, served by the registry `Run` key or Task Scheduler.
  windows,

  /// macOS, served by a launchd user agent.
  macos,

  /// Every other operating system. No autostart mechanism is available.
  unsupported,
}

/// Maps an operating system name onto the backend that serves it.
///
/// [operatingSystem] is the value of `Platform.operatingSystem`, which is
/// documented as lower case. The comparison is case insensitive anyway, so a
/// caller threading the name through by hand is not silently routed to
/// [AutostartPlatform.unsupported] over a capital letter.
AutostartPlatform resolveAutostartPlatform(String operatingSystem) {
  return switch (operatingSystem.toLowerCase()) {
    'windows' => AutostartPlatform.windows,
    'macos' => AutostartPlatform.macos,
    _ => AutostartPlatform.unsupported,
  };
}
