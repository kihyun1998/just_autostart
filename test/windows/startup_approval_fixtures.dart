/// Bytes copied verbatim from a real machine's
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run`.
///
/// These are the measured evidence behind the format, which Microsoft does not
/// document. They live in one place so the three test files that need them
/// cannot drift into disagreeing about what Windows writes.
library;

import 'dart:typed_data';

/// What Windows stores for an entry the user has **not** disabled.
///
/// Read identically on every enabled entry probed — OneDrive, Warp, Adobe's
/// synchroniser, Edge's auto-launch.
Uint8List realEnabledApproval() => Uint8List.fromList([
  0x02, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]);

/// What Windows stores for an entry the user switched **off** in Task Manager.
///
/// The odd first byte carries the decision. Bytes 4-11 are a little-endian
/// `FILETIME` recording *when* they did it — the half of the format the
/// reference implementation's comment does not mention, and which this package
/// reads past rather than interpreting.
Uint8List realDisabledApproval() => Uint8List.fromList([
  0x03, 0x00, 0x00, 0x00, //
  0x12, 0x8F, 0x2C, 0x11, 0xCA, 0x0F, 0xDC, 0x01,
]);
