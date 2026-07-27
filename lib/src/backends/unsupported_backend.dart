import '../autostart_backend.dart';
import '../exceptions.dart';

/// The backend for platforms with no autostart mechanism.
///
/// Every operation throws [UnsupportedPlatformException]. In particular
/// [isEnabled] throws rather than returning `false`: a quiet `false` reads as
/// "registered nothing yet" and would let a developer ship a toggle that can
/// never turn on, discovering it only from a user's bug report.
final class UnsupportedPlatformBackend implements AutostartBackend {
  /// Creates a backend that refuses every operation, naming [operatingSystem].
  const UnsupportedPlatformBackend(this.operatingSystem);

  /// The operating system this backend was asked to serve.
  final String operatingSystem;

  @override
  Future<void> enable() async =>
      throw UnsupportedPlatformException(operatingSystem);

  @override
  Future<void> disable() async =>
      throw UnsupportedPlatformException(operatingSystem);

  @override
  Future<bool> isEnabled() async =>
      throw UnsupportedPlatformException(operatingSystem);
}
