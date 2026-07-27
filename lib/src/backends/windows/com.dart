import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';

/// A COM interface pointer.
///
/// `dart:ffi` has no COM-aware type. The native type is always `IUnknown*` or
/// one of its descendants; what every one of them has in common is that the
/// first machine word is a pointer to the vtable, which is exactly what
/// `Pointer<IntPtr>` describes.
typedef ComPtr = Pointer<IntPtr>;

/// A `GUID` — an interface or class identifier.
///
/// The field layout is what makes a GUID **mixed-endian**: [data1], [data2] and
/// [data3] are integers and are stored least-significant byte first on x86,
/// while [data4] is a byte array and is stored exactly as written. Treating the
/// whole thing as one 16-byte blob produces a GUID that is wrong in its first
/// eight bytes only, which surfaces as `E_NOINTERFACE` far from the mistake.
final class Guid extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Array(8)
  external Array<Uint8> data4;
}

/// A `VARIANT`.
///
/// 24 bytes on x64: a 2-byte type tag, three 2-byte reserved fields, then a
/// 16-byte union. This package only ever constructs the empty variant — see
/// [emptyVariant] — so the union's members are not spelled out, only its size.
///
/// **The union is two machine words, not one.** Most of its members are a
/// pointer or smaller, but `BRECORD` is `{PVOID pvRecord; IRecordInfo*
/// pRecInfo;}` — two pointers — and that is what sets the size. Modelling it as
/// a single word yields a 16-byte struct that compiles, allocates and reads
/// back cleanly.
///
/// The size matters more than it looks, because every `VARIANT` parameter is
/// passed **by value**. Getting it wrong does not corrupt one argument; it
/// shifts every argument that follows it — and `RegisterTaskDefinition` takes
/// three variants with four more parameters behind them.
final class Variant extends Struct {
  @Uint16()
  external int vt;

  @Uint16()
  external int reserved1;

  @Uint16()
  external int reserved2;

  @Uint16()
  external int reserved3;

  /// The first machine word of the union — where a pointer, a handle or an
  /// integer member lands. Named for its position and not for a value, because
  /// what it holds depends entirely on [vt].
  @Int64()
  external int unionWord0;

  /// The second machine word of the union. Only `BRECORD` reaches it, and this
  /// package never constructs one — it exists so the struct is the size the ABI
  /// expects.
  @Int64()
  external int unionWord1;
}

/// `VT_EMPTY` — the variant that means "no value supplied".
const int vtEmpty = 0;

/// Fills a GUID from its canonical text form, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
///
/// Parsing text rather than writing eleven field assignments per identifier is
/// deliberate: the identifiers can then be pasted from the SDK header unaltered
/// and compared against it by eye, and the byte layout — the part that is
/// actually easy to get wrong — exists once instead of once per GUID.
///
/// Throws [ArgumentError] for anything that is not in that exact form. A
/// malformed identifier is a typo in this package's own source, not a condition
/// the caller could have anticipated.
Pointer<Guid> allocateGuid(Arena arena, String text) {
  if (!_guidPattern.hasMatch(text)) {
    throw ArgumentError.value(text, 'text', 'not a canonical GUID');
  }

  final guid = arena<Guid>();
  guid.ref
    ..data1 = int.parse(text.substring(0, 8), radix: 16)
    ..data2 = int.parse(text.substring(9, 13), radix: 16)
    ..data3 = int.parse(text.substring(14, 18), radix: 16);

  // The last two groups are one 8-byte field, so the separator between them is
  // skipped rather than treated as a boundary.
  final tail = text.substring(19, 23) + text.substring(24);
  for (var i = 0; i < 8; i++) {
    guid.ref.data4[i] = int.parse(tail.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return guid;
}

final _guidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Allocates a `VT_EMPTY` variant.
///
/// The arena zeroes what it allocates, so this only has to name the type tag —
/// which is itself zero. It is written out anyway: a reader should not have to
/// know that `VT_EMPTY == 0` to see that this is the empty variant.
Pointer<Variant> emptyVariant(Arena arena) =>
    arena<Variant>()..ref.vt = vtEmpty;

/// Whether an `HRESULT` reports success.
///
/// Success is `hr >= 0`, **not** `hr == 0`: `S_FALSE` is 1 and is a success.
bool succeeded(int hr) => hr >= 0;

/// Throws when [hr] reports failure, naming [operation].
void checkHResult(int hr, String operation) {
  if (succeeded(hr)) return;

  final unsigned = hr & 0xFFFFFFFF;
  throw AutostartOsException(
    operation: operation,
    detail: _describeHResult(unsigned),
    errorCode: unsigned,
  );
}

String _describeHResult(int unsigned) {
  final hex = '0x${unsigned.toRadixString(16).padLeft(8, '0')}';
  return switch (unsigned) {
    _eNoInterface => 'the object does not implement that interface ($hex)',
    _eInvalidArg => 'an argument was not valid ($hex)',
    _eAccessDenied => 'access denied ($hex)',
    _coeNotInitialized => 'COM was not initialised on this thread ($hex)',
    _hresultFileNotFound || _hresultPathNotFound => 'it does not exist ($hex)',
    _ => 'HRESULT $hex',
  };
}

/// `E_NOINTERFACE`.
const int _eNoInterface = 0x80004002;

/// `E_INVALIDARG`.
const int _eInvalidArg = 0x80070057;

/// `E_ACCESSDENIED`.
const int _eAccessDenied = 0x80070005;

/// `CO_E_NOTINITIALIZED`.
const int _coeNotInitialized = 0x800401F0;

/// `ERROR_FILE_NOT_FOUND` as an `HRESULT`.
const int _hresultFileNotFound = 0x80070002;

/// `ERROR_PATH_NOT_FOUND` as an `HRESULT`.
const int _hresultPathNotFound = 0x80070003;

/// Whether [hr] reports that the thing asked for is not there.
///
/// Task Scheduler answers with **either** of two codes, and which one depends
/// on how deep the miss is: a missing task or a missing folder directly under
/// an existing one gives `ERROR_FILE_NOT_FOUND`, while a missing *intermediate*
/// folder gives `ERROR_PATH_NOT_FOUND`. Testing only the first turns a nested
/// folder that is simply absent into a thrown failure, in exactly the methods
/// documented as answering a question rather than raising.
bool reportsAbsent(int hr) {
  final unsigned = hr & 0xFFFFFFFF;
  return unsigned == _hresultFileNotFound || unsigned == _hresultPathNotFound;
}

/// `RPC_E_CHANGED_MODE` — COM is already up on this thread, in the other
/// apartment model.
const int _rpcEChangedMode = 0x80010106;

/// Runs [body] with COM initialised on the calling thread.
///
/// Three facts shape this:
///
/// 1. **The apartment is per-thread**, and a Dart isolate is not pinned to an
///    OS thread across event-loop turns. Initialising once and leaving it up
///    would work until the isolate was rescheduled and then fail with
///    `CO_E_NOTINITIALIZED`. So the pairing is scoped instead — and [body] must
///    therefore be **synchronous**, because a thread cannot be swapped out from
///    under synchronous Dart code.
/// 2. **`RPC_E_CHANGED_MODE` is not a failure for us.** It means the host
///    process already initialised COM in the other apartment. COM is up, which
///    is all this package needs — but the call did *not* take a reference, so
///    the matching `CoUninitialize` must not happen. Treating it as an error
///    would break this package inside any host that initialised COM first.
/// 3. **`S_FALSE` is a success that does take a reference.** It means the thread
///    was already initialised in the same model. Uninitialising is then
///    required, not optional; skipping it would leak the host's apartment.
///
/// The multi-threaded model is asked for because this package's target is a
/// console program with no message loop, and an apartment-threaded thread owes
/// one. When the host has already chosen the other model, fact 2 applies and
/// the calls run in whatever apartment is there.
T withCom<T>(T Function() body) {
  final hr = _coInitializeEx(nullptr, _coinitMultithreaded);

  // Only a success took a reference; `RPC_E_CHANGED_MODE` did not.
  final owned = succeeded(hr);
  if (!owned && (hr & 0xFFFFFFFF) != _rpcEChangedMode) {
    checkHResult(hr, 'CoInitializeEx');
  }

  try {
    final result = body();

    // The synchronous requirement above is not something the type system can
    // hold: `T` binds happily to `Future`, so `withCom(() async { … })`
    // compiles. It would also be catastrophic — the body would return at its
    // first `await`, this `finally` would tear the apartment down immediately,
    // and every COM release the body had arranged would run afterwards,
    // against a thread with no apartment. That is not an exception, it is heap
    // corruption. So the one thing the type system cannot refuse is refused
    // here.
    if (result is Future) {
      throw StateError(
        'withCom body must be synchronous: COM apartment state is per-thread '
        'and cannot survive an await',
      );
    }
    return result;
  } finally {
    if (owned) _coUninitialize();
  }
}

/// `COINIT_MULTITHREADED`.
const int _coinitMultithreaded = 0x0;

/// Creates the COM object identified by [clsid] and returns [iid] on it.
///
/// The pointer is registered with [arena], so it is released when the arena is
/// — on the failure path as much as the success path.
ComPtr createInstance(Arena arena, String clsid, String iid) {
  final result = arena<ComPtr>();
  final hr = _coCreateInstance(
    allocateGuid(arena, clsid),
    nullptr,
    _clsctxInprocServer | _clsctxLocalServer,
    allocateGuid(arena, iid),
    result,
  );
  checkHResult(hr, 'CoCreateInstance');
  return ownInterface(arena, result.value);
}

// `Schedule.Service` resolves to an in-process DLL that forwards to the Task
// Scheduler service over RPC, so `CLSCTX_INPROC_SERVER` is the context that
// actually satisfies it here. `CLSCTX_LOCAL_SERVER` is asked for alongside it
// because that is a registration detail of one Windows build rather than a
// documented contract, and naming only the context observed on one machine
// would be fitting the code to that machine.
const int _clsctxInprocServer = 0x1;
const int _clsctxLocalServer = 0x4;

/// Ties [pointer]'s lifetime to [arena], so it is released exactly once when the
/// arena is.
///
/// This is the whole release discipline. Interface pointers are acquired in a
/// dozen places across a task registration, and "every one released exactly
/// once, on both paths" is not something a chain of hand-written `finally`
/// blocks stays true to as the code changes. Registering ownership at the point
/// of acquisition makes it structural instead.
ComPtr ownInterface(Arena arena, ComPtr pointer) =>
    arena.using(pointer, comRelease);

/// Reads the function pointer in [slot] of [self]'s vtable.
///
/// A COM interface pointer points at an object whose first machine word points
/// at an array of function pointers. Every step is checked — the pointer, the
/// vtable, and the slot's own contents — because a null one dereferenced here
/// takes the whole process down with no Dart stack.
///
/// The slot index cannot be checked — a wrong one yields a perfectly valid
/// function pointer to the wrong function, which is why every index in this
/// package is taken from `taskschd.h` rather than from documentation, and why
/// this sits on the FFI sacred path.
Pointer<NativeFunction<T>> vtableSlot<T extends Function>(
  ComPtr self,
  int slot,
) {
  final function = _vtableSlotOrNull<T>(self, slot);
  if (function == null) {
    throw StateError(
      'COM interface pointer does not lead to a function at vtable slot $slot',
    );
  }
  return function;
}

/// [vtableSlot] without the throw, for the one caller that must not raise.
///
/// Returns `null` when the interface pointer, the vtable pointer, or the slot's
/// own contents are null. The **slot's contents** matter as much as the two
/// indirections above it: an address of zero here becomes a call through a null
/// function pointer, which is an access violation with no Dart stack — the
/// exact failure the checks exist to replace.
Pointer<NativeFunction<T>>? _vtableSlotOrNull<T extends Function>(
  ComPtr self,
  int slot,
) {
  if (self == nullptr || self.value == 0) return null;

  final function = (Pointer<IntPtr>.fromAddress(self.value) + slot).value;
  if (function == 0) return null;

  return Pointer<NativeFunction<T>>.fromAddress(function);
}

/// `IUnknown::Release` — vtable slot 2.
///
/// **This must not throw.** It runs as an arena release callback, and
/// `Arena.releaseAll` abandons the rest of its list when a callback raises — so
/// one throw here would leak every interface still queued behind it *and* every
/// allocation in the arena. A pointer that does not lead to a function is
/// therefore skipped rather than reported: there is nothing to release, and
/// nothing a caller could do about it at that point anyway.
void comRelease(ComPtr self) {
  final release = _vtableSlotOrNull<Uint32 Function(ComPtr)>(self, 2);
  if (release == null) return;

  release.asFunction<int Function(ComPtr)>()(self);
}

/// `IUnknown::QueryInterface` — vtable slot 0.
///
/// The returned pointer is registered with [arena]. `QueryInterface` takes a
/// reference of its own, so the result must be released independently of the
/// pointer it was asked on — which is exactly what registering it separately
/// arranges.
ComPtr queryInterface(Arena arena, ComPtr self, String iid, String operation) {
  final result = arena<ComPtr>();
  final hr =
      vtableSlot<Int32 Function(ComPtr, Pointer<Guid>, Pointer<ComPtr>)>(
        self,
        0,
      ).asFunction<int Function(ComPtr, Pointer<Guid>, Pointer<ComPtr>)>()(
        self,
        allocateGuid(arena, iid),
        result,
      );
  checkHResult(hr, operation);
  return ownInterface(arena, result.value);
}

/// Allocates a `BSTR` holding [value], freed with the arena.
///
/// A `BSTR` is not a wide string with a different name. Its length in bytes
/// lives in the four bytes *before* the pointer, and it comes from the OLE
/// automation allocator — so it must be freed with `SysFreeString` and with
/// nothing else. Registering that with the arena is what keeps the two
/// allocators from being crossed on a failure path.
Pointer<Utf16> allocateBstr(Arena arena, String value) {
  final bstr = _sysAllocString(value.toNativeUtf16(allocator: arena));
  if (bstr == nullptr) {
    throw const AutostartOsException(
      operation: 'SysAllocString',
      detail: 'out of memory',
    );
  }
  return arena.using(bstr, _sysFreeString);
}

/// Frees a `BSTR` that came **from** a COM call rather than from [allocateBstr].
///
/// A property getter returns a string the callee allocated and the caller owns;
/// there is no arena holding it, so it is released explicitly. Freeing it with
/// anything but `SysFreeString` corrupts the OLE automation heap, and not
/// freeing it leaks — which is why the read path copies the text out and calls
/// this immediately rather than passing the pointer around.
void freeBstr(Pointer<Utf16> bstr) {
  if (bstr == nullptr) return;
  _sysFreeString(bstr);
}

/// Opens a Windows system DLL that is registered as a **KnownDLL**.
///
/// Loading a DLL by bare name normally follows the search order, which begins
/// with the directory the program was started from — so a file planted next to
/// a consumer's executable would be loaded in place of the system one. That is
/// not true of the handful of libraries listed under
/// `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\KnownDLLs`:
/// the loader resolves those from a section object mapped at boot and never
/// consults the search path at all, so the bare name cannot be redirected.
///
/// `ole32.dll` and `oleaut32.dll` are both on that list, checked on a real
/// machine — as is the `advapi32.dll` that `registry.dart` opens by bare name,
/// which is why that one needs no change either.
///
/// This is deliberately **not** an absolute `%SystemRoot%\System32\…` path,
/// which looks like the safer spelling and is not: it reintroduces a path that
/// comes from the environment, where the bare name reintroduces nothing. The
/// sibling `just_font_scan` uses the absolute form; its rationale does not hold
/// for these libraries.
DynamicLibrary loadKnownDll(String name) => DynamicLibrary.open(name);

// Lazily initialised, as every top-level `final` in Dart is, so importing this
// file on Linux or macOS never opens a Windows DLL.
final DynamicLibrary _ole32 = loadKnownDll('ole32.dll');
final DynamicLibrary _oleaut32 = loadKnownDll('oleaut32.dll');

final _coInitializeEx = _ole32
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('CoInitializeEx');

final _coUninitialize = _ole32.lookupFunction<Void Function(), void Function()>(
  'CoUninitialize',
);

final _coCreateInstance = _ole32
    .lookupFunction<
      Int32 Function(
        Pointer<Guid>,
        Pointer<Void>,
        Uint32,
        Pointer<Guid>,
        Pointer<ComPtr>,
      ),
      int Function(
        Pointer<Guid>,
        Pointer<Void>,
        int,
        Pointer<Guid>,
        Pointer<ComPtr>,
      )
    >('CoCreateInstance');

final _sysAllocString = _oleaut32
    .lookupFunction<
      Pointer<Utf16> Function(Pointer<Utf16>),
      Pointer<Utf16> Function(Pointer<Utf16>)
    >('SysAllocString');

final _sysFreeString = _oleaut32
    .lookupFunction<
      Void Function(Pointer<Utf16>),
      void Function(Pointer<Utf16>)
    >('SysFreeString');
