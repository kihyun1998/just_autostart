import 'dart:typed_data';

/// The registry key Windows uses to record the user's own decision about a
/// startup entry — the toggle in Task Manager's "Startup apps" tab.
///
/// Separate from the `Run` key on purpose: an application writes its
/// registration to one store, and the user's veto lives in the other. Reading
/// only the first reports "enabled" for an entry that will never launch.
const startupApprovedRunKeyPath =
    r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

/// The number of bytes Windows stores per approval entry.
const _approvalValueLength = 12;

/// The value Windows itself stores for an entry the user has not disabled.
///
/// Measured on a real machine rather than taken from documentation, which does
/// not exist for this format: every enabled entry read as
/// `02 00 00 00 00 00 00 00 00 00 00 00`, and a user-disabled entry as `03`,
/// three zero bytes, then a little-endian **FILETIME** recording when it was
/// switched off. Only the first byte carries the decision; the timestamp is
/// Windows' own bookkeeping and this package does not write one.
///
/// Returns a fresh list each call, so a caller cannot mutate the next one.
Uint8List enabledApprovalValue() => Uint8List(_approvalValueLength)..[0] = 0x02;

/// Whether the user has left this entry allowed to start.
///
/// The decision is the **parity of the first byte** — odd means the user
/// switched it off. An absent or empty value also means allowed: Windows writes
/// nothing here until the toggle is first touched, so a freshly registered
/// entry has no approval value at all and is nonetheless enabled.
///
/// Anything past the first byte is ignored, including the timestamp, so an
/// entry the user re-enabled reads as approved whether or not Windows kept the
/// bytes from when it was disabled.
bool isStartupApproved(Uint8List? value) {
  if (value == null || value.isEmpty) return true;
  return value.first.isEven;
}
