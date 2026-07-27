/// What a platform backend must be able to do.
///
/// Every backend registers, unregisters, and reports — nothing more. The
/// differences between platforms live in *where* a registration is stored, not
/// in what operations exist, which is why this interface stays at three
/// methods across Windows, macOS, and the unsupported case.
abstract interface class AutostartBackend {
  /// Registers the configured executable to launch at login.
  ///
  /// Idempotent: enabling something already enabled leaves one registration.
  Future<void> enable();

  /// Removes the registration, if there is one.
  ///
  /// Idempotent: disabling something that was never enabled is not an error.
  Future<void> disable();

  /// Whether the configured executable will actually launch at login.
  ///
  /// This is stricter than "did we write a registration". A backend also
  /// accounts for the user having switched the entry off in the operating
  /// system's own interface, and for a registration left behind pointing at
  /// some other executable.
  Future<bool> isEnabled();
}
