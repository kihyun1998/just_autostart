import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
import 'com.dart';

/// Returns the security identifier of the user this process is running as, in
/// the string form `S-1-5-21-…`.
///
/// A logon trigger with no `UserId` fires when **any** user logs on, and the
/// task then runs as its principal — so one user logging in would start another
/// user's program. Naming the user is what confines the trigger to the account
/// that asked for it.
///
/// The SID is used rather than `DOMAIN\Name` because it is what the account
/// actually is: a rename leaves it unchanged, it cannot be ambiguous between a
/// local and a domain account, and it is the form Task Scheduler itself writes
/// back into a task's XML.
///
/// Reads the process token rather than `%USERNAME%`, which is an ordinary
/// environment variable and says whatever the process was started with.
String currentUserSid() {
  return using((arena) {
    final token = arena<IntPtr>();
    if (_openProcessToken(_currentProcess, _tokenQuery, token) == 0) {
      _failLastError('OpenProcessToken');
    }

    try {
      // Two calls, the first only to learn the size. A SID is variable-length —
      // its authority count decides it — so there is no buffer size that is
      // correct by construction.
      final size = arena<Uint32>();
      _getTokenInformation(token.value, _tokenUser, nullptr, 0, size);
      if (size.value == 0) _failLastError('GetTokenInformation');

      final buffer = arena<Uint8>(size.value);
      if (_getTokenInformation(
            token.value,
            _tokenUser,
            buffer.cast(),
            size.value,
            size,
          ) ==
          0) {
        _failLastError('GetTokenInformation');
      }

      // `TOKEN_USER` is a `SID_AND_ATTRIBUTES`, whose first field is the `PSID`.
      // The SID itself lives elsewhere in the same buffer, which is why the
      // whole buffer has to outlive this read.
      final sid = buffer.cast<Pointer<Void>>().value;

      final text = arena<Pointer<Utf16>>();
      if (_convertSidToStringSidW(sid, text) == 0) {
        _failLastError('ConvertSidToStringSidW');
      }

      try {
        return text.value.toDartString();
      } finally {
        // Allocated by the OS with `LocalAlloc`, so it is freed with `LocalFree`
        // and not with the arena.
        _localFree(text.value.cast());
      }
    } finally {
      _closeHandle(token.value);
    }
  });
}

/// Whether [accountOrSid] names the user this process is running as.
///
/// Needed because **Windows hands the same identity back in more than one
/// form.** A scheduled task's principal is *stored* as the SID it was given —
/// the XML shows one — but `IPrincipal::get_UserId` resolves it to an account
/// name on the way out. So a comparison against [currentUserSid] never matches,
/// and a comparison against a name would have to guess which of `Name`,
/// `DOMAIN\Name` or `Name@domain` it was given.
///
/// Resolving whatever arrives back to a SID and comparing *those* removes the
/// guess: a SID is what the account actually is.
bool isCurrentUser(String accountOrSid) {
  final mine = currentUserSid().toUpperCase();
  if (accountOrSid.toUpperCase() == mine) return true;

  final resolved = _sidForAccountName(accountOrSid);
  return resolved != null && resolved.toUpperCase() == mine;
}

/// Resolves an account name to its SID, or `null` when it names nobody.
///
/// A name that cannot be resolved is not an error here. It means the account is
/// gone, or belongs to a domain this machine cannot reach — in either case it is
/// not this user, which is the only question being asked.
String? _sidForAccountName(String name) {
  return using((arena) {
    final wide = name.toNativeUtf16(allocator: arena);
    final sidSize = arena<Uint32>();
    final domainSize = arena<Uint32>();
    final use = arena<Int32>();

    // The usual two calls: the first exists only to learn both sizes. A SID is
    // variable-length and so is the domain name, so neither buffer has a size
    // that is correct by construction.
    _lookupAccountNameW(
      nullptr,
      wide,
      nullptr,
      sidSize,
      nullptr,
      domainSize,
      use,
    );
    if (sidSize.value == 0) return null;

    final sid = arena<Uint8>(sidSize.value);
    final domain = arena<Uint16>(domainSize.value + 1);
    if (_lookupAccountNameW(
          nullptr,
          wide,
          sid.cast(),
          sidSize,
          domain.cast(),
          domainSize,
          use,
        ) ==
        0) {
      return null;
    }

    final text = arena<Pointer<Utf16>>();
    if (_convertSidToStringSidW(sid.cast(), text) == 0) return null;

    try {
      return text.value.toDartString();
    } finally {
      _localFree(text.value.cast());
    }
  });
}

Never _failLastError(String operation) {
  final code = _getLastError();
  throw AutostartOsException(
    operation: operation,
    detail: 'Win32 error $code',
    errorCode: code,
  );
}

/// `GetCurrentProcess()` — a pseudo-handle documented as the constant `-1`.
///
/// Hardcoded rather than bound: the function does nothing but return this, and
/// binding it would add a call to learn a value the documentation fixes.
final Pointer<Void> _currentProcess = Pointer<Void>.fromAddress(-1);

/// `TOKEN_QUERY`.
const int _tokenQuery = 0x0008;

/// `TokenUser`, the first member of `TOKEN_INFORMATION_CLASS`.
const int _tokenUser = 1;

final DynamicLibrary _advapi32 = loadKnownDll('advapi32.dll');
final DynamicLibrary _kernel32 = loadKnownDll('kernel32.dll');

final _openProcessToken = _advapi32
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Pointer<IntPtr>),
      int Function(Pointer<Void>, int, Pointer<IntPtr>)
    >('OpenProcessToken');

final _getTokenInformation = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
    >('GetTokenInformation');

final _convertSidToStringSidW = _advapi32
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
      int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
    >('ConvertSidToStringSidW');

final _lookupAccountNameW = _advapi32
    .lookupFunction<
      Int32 Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Uint32>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Int32>,
      ),
      int Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Uint32>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Int32>,
      )
    >('LookupAccountNameW');

final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

final _localFree = _kernel32
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('LocalFree');

final _getLastError = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
