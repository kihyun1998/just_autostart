import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';

/// `HKEY_CURRENT_USER`, as the address of its predefined handle.
///
/// **Not `0x80000001`.** The Win32 header defines it as
/// `((HKEY)(ULONG_PTR)((LONG)0x80000001))`; the `(LONG)` cast makes the value
/// signed *before* it widens, so on 64-bit the handle is `0xFFFFFFFF80000001`.
/// Passing the unsigned literal produces a handle Windows does not recognise.
/// `package:win32` spells it the same way — `Pointer.fromAddress(-2147483647)`.
const int hkeyCurrentUser = -2147483647;

/// Where in the registry a set of values lives.
///
/// This is the **only** seam in the Windows backend. Tests point it at a scratch
/// subkey and run the real advapi32 calls against it: a test that passed against
/// a faked registry would say nothing about whether the FFI signatures are
/// right, which is the single most likely thing to be wrong here.
///
/// The hive is **not** configurable. Every operation targets
/// `HKEY_CURRENT_USER`, which is what makes "this package never needs
/// elevation" a structural property rather than a promise.
final class RegistryLocation {
  /// Creates a location at [path] under the current user.
  const RegistryLocation({required this.path});

  /// The key path below `HKEY_CURRENT_USER`, backslash-separated and without a
  /// leading separator.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is RegistryLocation && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'RegistryLocation($path)';
}

/// Reads and writes registry values through hand-written `advapi32` bindings.
///
/// There is no interface over this and no fake of it. The dangerous part *is*
/// the marshalling, so the tests drive the real thing at a scratch location.
final class WindowsRegistry {
  /// Creates a registry accessor.
  const WindowsRegistry();

  /// Returns the string value named [name], or `null` when there is no string
  /// there to read.
  ///
  /// Reads `REG_SZ` and `REG_EXPAND_SZ` without expanding environment
  /// variables, so the comparison in `isEnabled()` sees what is actually stored
  /// rather than what it would resolve to today.
  ///
  /// A value of some **other** type — a `REG_DWORD` or `REG_BINARY` another
  /// program stored under the same name — also reads as `null` rather than
  /// throwing. Both callers treat `null` as "not ours", which is the safe
  /// answer: a name collision with a non-string value must not turn `disable()`
  /// into a crash. `win32_registry` behaves the same way.
  String? readString(RegistryLocation location, String name) => _read(
    location,
    name,
    _rrfRtRegSz | _rrfRtRegExpandSz | _rrfNoexpand,
    // RegGetValueW guarantees a null terminator for string types, which
    // RegQueryValueExW does not — a value another program wrote without one
    // would otherwise be read past its end.
    (data, _) => data.cast<Utf16>().toDartString(),
  );

  /// Returns the binary value named [name], or `null` when there is no binary
  /// value there to read.
  ///
  /// As with [readString], a value of some other type reads as `null` rather
  /// than throwing.
  Uint8List? readBinary(RegistryLocation location, String name) => _read(
    location,
    name,
    _rrfRtRegBinary,
    // `asTypedList` is a *view* into the arena's memory, which is freed when
    // this scope exits. Returning it would hand the caller freed memory, so
    // the bytes are copied out.
    (data, lengthInBytes) =>
        Uint8List.fromList(data.asTypedList(lengthInBytes)),
  );

  /// Writes [value] as a `REG_SZ` under [name], creating the key if needed.
  void writeString(RegistryLocation location, String name, String value) {
    _write(
      location,
      name,
      _regSz,
      // Two bytes per UTF-16 code unit, plus two for the terminator.
      // `String.length` is already in code units, so surrogate pairs are
      // counted correctly without any extra work.
      (arena) => (
        value.toNativeUtf16(allocator: arena).cast<Uint8>(),
        value.length * 2 + 2,
      ),
    );
  }

  /// Writes [value] as a `REG_BINARY` under [name], creating the key if needed.
  void writeBinary(RegistryLocation location, String name, Uint8List value) {
    _write(location, name, _regBinary, (arena) {
      final data = arena<Uint8>(value.length);
      data.asTypedList(value.length).setAll(0, value);
      return (data, value.length);
    });
  }

  /// Reads a value of the types selected by [flags] and converts it.
  ///
  /// Shared by [readString] and [readBinary] so the size negotiation exists
  /// once: it is on this package's second sacred path, and two copies of it
  /// would be two places for the arithmetic to drift.
  T? _read<T extends Object>(
    RegistryLocation location,
    String name,
    int flags,
    T Function(Pointer<Uint8> data, int lengthInBytes) convert,
  ) {
    return using((arena) {
      final subKey = location.path.toNativeUtf16(allocator: arena);
      final valueName = name.toNativeUtf16(allocator: arena);
      final size = arena<Uint32>();

      // A fast path sized for the common case, then a retry at whatever size
      // the call reports. The retry is a loop rather than a single second
      // attempt because the value can grow again between the two calls — a
      // bounded loop keeps that from becoming either a truncation or a hang.
      var capacity = 256;
      for (var attempt = 0; attempt < 4; attempt++) {
        final buffer = arena<Uint8>(capacity);
        size.value = capacity;

        final status = _regGetValueW(
          Pointer.fromAddress(hkeyCurrentUser),
          subKey,
          valueName,
          flags,
          nullptr,
          buffer.cast(),
          size,
        );

        if (status == _errorSuccess) return convert(buffer, size.value);
        if (status == _errorFileNotFound) return null;
        if (status == _errorUnsupportedType) return null;
        if (status != _errorMoreData) _fail('RegGetValueW', status);

        capacity = size.value;
      }

      throw const AutostartOsException(
        operation: 'RegGetValueW',
        detail: 'value kept growing between size negotiation attempts',
      );
    });
  }

  void _write(
    RegistryLocation location,
    String name,
    int type,
    (Pointer<Uint8>, int) Function(Arena arena) marshal,
  ) {
    using((arena) {
      final handle = _openKey(arena, location, create: true);
      try {
        final (data, lengthInBytes) = marshal(arena);
        final status = _regSetValueExW(
          handle,
          name.toNativeUtf16(allocator: arena),
          0,
          type,
          data,
          lengthInBytes,
        );
        if (status != _errorSuccess) _fail('RegSetValueExW', status);
      } finally {
        _regCloseKey(handle);
      }
    });
  }

  /// Deletes the value named [name].
  ///
  /// Returns `false` when the key or the value was already absent, so the
  /// caller can stay idempotent without inspecting error codes.
  bool deleteValue(RegistryLocation location, String name) {
    return using((arena) {
      final Pointer<NativeType> handle;
      try {
        handle = _openKey(arena, location, create: false);
      } on AutostartOsException catch (error) {
        if (error.errorCode == _errorFileNotFound) return false;
        rethrow;
      }

      try {
        final status = _regDeleteValueW(
          handle,
          name.toNativeUtf16(allocator: arena),
        );
        if (status == _errorFileNotFound) return false;
        if (status != _errorSuccess) _fail('RegDeleteValueW', status);
        return true;
      } finally {
        _regCloseKey(handle);
      }
    });
  }

  Pointer<NativeType> _openKey(
    Arena arena,
    RegistryLocation location, {
    required bool create,
  }) {
    final result = arena<Pointer<NativeType>>();
    final path = location.path.toNativeUtf16(allocator: arena);
    final hive = Pointer<NativeType>.fromAddress(hkeyCurrentUser);

    final status = create
        ? _regCreateKeyExW(
            hive,
            path,
            0,
            nullptr,
            _regOptionNonVolatile,
            _keyAllAccess,
            nullptr,
            result,
            nullptr,
          )
        : _regOpenKeyExW(hive, path, 0, _keyAllAccess, result);

    if (status != _errorSuccess) {
      _fail(create ? 'RegCreateKeyExW' : 'RegOpenKeyExW', status);
    }
    return result.value;
  }
}

Never _fail(String operation, int status) => throw AutostartOsException(
  operation: operation,
  detail: _describe(status),
  errorCode: status,
);

String _describe(int status) => switch (status) {
  _errorFileNotFound => 'the key or value does not exist',
  _errorAccessDenied => 'access denied',
  _errorInvalidParameter => 'the key path is not valid',
  _errorMoreData => 'the buffer was too small',
  _errorUnsupportedType => 'the value is not of a supported type',
  _ => 'Win32 error $status',
};

// Only the constants this package actually uses. Their values are pinned by the
// integration tests against a real scratch key rather than by reading a header:
// a wrong access mask fails with ERROR_ACCESS_DENIED, a wrong type tag shows up
// as the wrong type in the registry.
const int _errorSuccess = 0;
const int _errorFileNotFound = 2;
const int _errorAccessDenied = 5;
const int _errorInvalidParameter = 87;
const int _errorMoreData = 234;
const int _errorUnsupportedType = 1630;

const int _regSz = 1;
const int _regBinary = 3;
const int _regOptionNonVolatile = 0;
const int _keyAllAccess = 0xF003F;

const int _rrfRtRegSz = 0x00000002;
const int _rrfRtRegExpandSz = 0x00000004;
const int _rrfRtRegBinary = 0x00000008;
const int _rrfNoexpand = 0x10000000;

// Lazily initialised, as every top-level `final` in Dart is. That is what lets
// this file be imported on Linux and macOS — the platform dispatch never
// touches these bindings off Windows, so `advapi32.dll` is never opened there.
final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

final _regCreateKeyExW = _advapi32
    .lookupFunction<
      Uint32 Function(
        Pointer,
        Pointer<Utf16>,
        Uint32,
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer,
        Pointer<Pointer<NativeType>>,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer,
        Pointer<Utf16>,
        int,
        Pointer<Utf16>,
        int,
        int,
        Pointer,
        Pointer<Pointer<NativeType>>,
        Pointer<Uint32>,
      )
    >('RegCreateKeyExW');

final _regOpenKeyExW = _advapi32
    .lookupFunction<
      Uint32 Function(
        Pointer,
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer<Pointer<NativeType>>,
      ),
      int Function(
        Pointer,
        Pointer<Utf16>,
        int,
        int,
        Pointer<Pointer<NativeType>>,
      )
    >('RegOpenKeyExW');

final _regSetValueExW = _advapi32
    .lookupFunction<
      Uint32 Function(
        Pointer,
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer<Uint8>,
        Uint32,
      ),
      int Function(Pointer, Pointer<Utf16>, int, int, Pointer<Uint8>, int)
    >('RegSetValueExW');

final _regGetValueW = _advapi32
    .lookupFunction<
      Uint32 Function(
        Pointer,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Uint32,
        Pointer<Uint32>,
        Pointer,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer,
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
        Pointer<Uint32>,
        Pointer,
        Pointer<Uint32>,
      )
    >('RegGetValueW');

final _regDeleteValueW = _advapi32
    .lookupFunction<
      Uint32 Function(Pointer, Pointer<Utf16>),
      int Function(Pointer, Pointer<Utf16>)
    >('RegDeleteValueW');

final _regCloseKey = _advapi32
    .lookupFunction<Uint32 Function(Pointer), int Function(Pointer)>(
      'RegCloseKey',
    );
