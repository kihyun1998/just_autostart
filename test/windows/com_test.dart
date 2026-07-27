@TestOn('windows')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/windows/com.dart';
import 'package:test/test.dart';

/// `IIDFromString` — Windows' own GUID parser, from `ole32.dll`.
///
/// The whole point of this binding is that it is **not us**. A test asserting
/// that our parser agrees with bytes we also wrote down would only prove the two
/// halves of one idea match; asserting it against the parser COM itself uses
/// proves the bytes are the ones `CoCreateInstance` will be handed.
///
/// It requires the braced form, which is why the fixtures are wrapped below.
final _iidFromString = loadKnownDll('ole32.dll')
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Guid>),
      int Function(Pointer<Utf16>, Pointer<Guid>)
    >('IIDFromString');

/// The 16 bytes a GUID occupies in memory.
List<int> _bytesOf(Pointer<Guid> guid) =>
    guid.cast<Uint8>().asTypedList(16).toList();

void main() {
  group('Guid', () {
    test('occupies the 16 bytes COM expects', () {
      expect(sizeOf<Guid>(), 16);
    });

    // Every GUID this package will ever pass to COM, checked against Windows.
    // A GUID is *mixed*-endian — the first three fields are little-endian
    // integers and the last eight are raw bytes in written order — so a parser
    // that treats it as one 16-byte blob is wrong in a way that only shows up
    // as E_NOINTERFACE much later.
    const fixtures = {
      'CLSID_TaskScheduler': _clsidTaskScheduler,
      'IID_ITaskService': _iidTaskService,
      'IID_ITaskFolder': '8cfac062-a080-4c15-9a88-aa7c2af80dfc',
      'IID_ITaskDefinition': 'f5bc8fc5-536d-4f77-b852-fbc1356fdeb6',
      'IID_IRegisteredTask': '9c86f320-dee3-4dd1-b972-a303f26b061e',
      'IID_IExecAction': '4c3d624d-fd6b-49a3-b9b7-09cb3cd3f047',
      'IID_IExecAction2': 'f2a82542-bda5-4e6b-9143-e2bf4f8987b6',
    };

    for (final MapEntry(key: name, value: text) in fixtures.entries) {
      test('parses $name the way Windows parses it', () {
        using((arena) {
          final ours = allocateGuid(arena, text);

          final theirs = arena<Guid>();
          final status = _iidFromString(
            '{$text}'.toNativeUtf16(allocator: arena),
            theirs,
          );

          expect(status, 0, reason: 'IIDFromString should have accepted $text');
          expect(_bytesOf(ours), _bytesOf(theirs));
        });
      });
    }

    // The mixed endianness, spelled out once so a future reader can see it
    // rather than infer it: `0f87369f` is stored least-significant byte first,
    // and `bd3e73e6154572dd` is stored as written.
    test(
      'stores the first three fields little-endian and the rest as written',
      () {
        using((arena) {
          final guid = allocateGuid(
            arena,
            '0f87369f-a4e5-4cfc-bd3e-73e6154572dd',
          );

          expect(_bytesOf(guid), [
            0x9f, 0x36, 0x87, 0x0f, // data1, reversed
            0xe5, 0xa4, //             data2, reversed
            0xfc, 0x4c, //             data3, reversed
            0xbd, 0x3e, 0x73, 0xe6, 0x15, 0x45, 0x72, 0xdd, // data4, as written
          ]);
        });
      },
    );

    test('accepts upper case', () {
      using((arena) {
        expect(
          _bytesOf(allocateGuid(arena, '0F87369F-A4E5-4CFC-BD3E-73E6154572DD')),
          _bytesOf(allocateGuid(arena, '0f87369f-a4e5-4cfc-bd3e-73e6154572dd')),
        );
      });
    });

    // A malformed GUID is a typo in this package's own source, not a condition
    // the program could not have known about — `ArgumentError`, per the
    // convention `exceptions.dart` documents.
    for (final malformed in const [
      '',
      '0f87369f-a4e5-4cfc-bd3e-73e6154572d', // one digit short
      '0f87369f-a4e5-4cfc-bd3e-73e6154572ddd', // one digit long
      '0f87369fa4e54cfcbd3e73e6154572dd', // no separators
      '{0f87369f-a4e5-4cfc-bd3e-73e6154572dd}', // braced
      '0f87369f-a4e5-4cfc-bd3e-73e615457zzz',
    ]) {
      test('rejects "$malformed"', () {
        expect(
          () => using((arena) => allocateGuid(arena, malformed)),
          throwsArgumentError,
        );
      });
    }
  });

  group('Variant', () {
    // 24 bytes on x64: a 2-byte VARTYPE, three 2-byte reserved fields, then a
    // 16-byte union — sized by `BRECORD`, its widest member, and not by the
    // single machine word every member this package builds would need. Every
    // VARIANT argument is passed by value, so a wrong size does not corrupt one
    // argument; it shifts every argument after it.
    test('occupies the 24 bytes the x64 ABI expects', () {
      expect(sizeOf<Variant>(), 24);
    });

    test('an empty variant is 24 zero bytes', () {
      using((arena) {
        final variant = emptyVariant(arena);

        expect(variant.ref.vt, vtEmpty);
        expect(variant.cast<Uint8>().asTypedList(24), everyElement(0));
      });
    });

    // The size and the zeroes above are necessary and not sufficient: a variant
    // that never reached the callee at all would satisfy both, because
    // `ITaskService::Connect` treats four empty variants and four *missing*
    // ones identically — it connects to the local machine either way. So this
    // sends a variant Windows must react to.
    //
    // `serverName` is given `VT_BSTR` naming a host that cannot exist. If the
    // 24 bytes land where the x64 ABI says they should, Task Scheduler tries
    // that host and fails with `ERROR_BAD_NETPATH`. If the type tag at offset 0
    // or the pointer at offset 8 landed anywhere else, the call would read as
    // empty and *succeed*. Success is the failure here.
    test('is passed by value into the argument slot the callee reads', () {
      withCom(() {
        using((arena) {
          final service = createInstance(
            arena,
            _clsidTaskScheduler,
            _iidTaskService,
          );

          final serverName = arena<Variant>();
          serverName.ref
            ..vt = _vtBstr
            ..unionWord0 = allocateBstr(
              arena,
              r'\\just.autostart.invalid',
            ).address;

          // `Connect` is vtable slot 10 — restated here rather than imported,
          // so this test disagrees with the implementation if either drifts.
          final hr =
              vtableSlot<
                    Int32 Function(ComPtr, Variant, Variant, Variant, Variant)
                  >(service, 10)
                  .asFunction<
                    int Function(ComPtr, Variant, Variant, Variant, Variant)
                  >()(
                service,
                serverName.ref,
                emptyVariant(arena).ref,
                emptyVariant(arena).ref,
                emptyVariant(arena).ref,
              );

          expect(
            hr & 0xFFFFFFFF,
            isNot(0),
            reason:
                'connecting to a host that does not exist must not succeed '
                '— S_OK means the variant never reached serverName',
          );
        });
      });
    });
  });

  group('vtableSlot', () {
    // A COM interface pointer is a pointer to a pointer to an array of function
    // pointers. Getting that double indirection wrong, or the slot arithmetic,
    // produces a *valid-looking* function pointer to the wrong code — which is
    // why this is proved against a hand-built table with known contents rather
    // than only through a live object.
    test('reads the function pointer at the requested slot', () {
      using((arena) {
        final table = arena<IntPtr>(8);
        for (var i = 0; i < 8; i++) {
          table[i] = 0x1000 + i * 0x10;
        }
        final object = arena<IntPtr>();
        object.value = table.address;

        for (var i = 0; i < 8; i++) {
          expect(
            vtableSlot<Void Function()>(object, i).address,
            0x1000 + i * 0x10,
          );
        }
      });
    });

    test(
      'refuses a null interface pointer instead of crashing the process',
      () {
        expect(() => vtableSlot<Void Function()>(nullptr, 0), throwsStateError);
      },
    );

    test('refuses an object whose vtable pointer is null', () {
      using((arena) {
        final object = arena<IntPtr>()..value = 0;

        expect(() => vtableSlot<Void Function()>(object, 0), throwsStateError);
      });
    });

    // The two indirections above are the obvious checks; this is the one that
    // is easy to leave out. A slot holding zero yields a function pointer that
    // is structurally fine and calls address zero — an access violation with no
    // Dart stack, which is exactly what checking the other two exists to
    // prevent.
    test('refuses a slot that holds no function', () {
      using((arena) {
        final table = arena<IntPtr>(4);
        table[3] = 0;
        final object = arena<IntPtr>()..value = table.address;

        expect(() => vtableSlot<Void Function()>(object, 3), throwsStateError);
      });
    });
  });

  group('BSTR', () {
    // A BSTR is not a plain wide string: its length in *bytes* is stored in the
    // four bytes immediately before the pointer. Reading that prefix directly
    // proves `SysAllocString` produced a real BSTR — checking it with
    // `SysStringLen` would only prove two oleaut32 calls agree.
    test('carries the byte-length prefix a BSTR is defined by', () {
      using((arena) {
        final bstr = allocateBstr(arena, 'JustAutostart');

        final prefix = Pointer<Uint32>.fromAddress(bstr.address - 4).value;
        expect(prefix, 'JustAutostart'.length * 2);
      });
    });

    test('round-trips the text', () {
      using((arena) {
        expect(
          allocateBstr(arena, r'C:\프로그램\도구.exe').toDartString(),
          r'C:\프로그램\도구.exe',
        );
      });
    });

    test('round-trips text outside the basic multilingual plane', () {
      using((arena) {
        final bstr = allocateBstr(arena, 'launch 🚀 now');

        expect(bstr.toDartString(), 'launch 🚀 now');
        expect(
          Pointer<Uint32>.fromAddress(bstr.address - 4).value,
          'launch 🚀 now'.length * 2,
        );
      });
    });

    test('round-trips an empty string', () {
      using((arena) {
        expect(allocateBstr(arena, '').toDartString(), '');
      });
    });
  });

  group('checkHResult', () {
    test('passes S_OK through', () {
      expect(() => checkHResult(0, 'Something'), returnsNormally);
    });

    // S_FALSE is a *success* code with a non-zero value. Testing `hr != 0`
    // instead of `hr < 0` would turn every one of these into a thrown failure.
    test('passes S_FALSE through', () {
      expect(() => checkHResult(1, 'Something'), returnsNormally);
    });

    test('turns a failure into the shared typed exception', () {
      expect(
        () => checkHResult(_asHresult(0x80070005), 'CoCreateInstance'),
        throwsA(
          isA<AutostartOsException>()
              .having((e) => e.operation, 'operation', 'CoCreateInstance')
              .having((e) => e.errorCode, 'errorCode', 0x80070005)
              .having((e) => e.message, 'message', contains('access denied')),
        ),
      );
    });

    // HRESULTs arrive as a signed 32-bit value, so E_INVALIDARG reads as a
    // large negative number. Reporting that to a user is useless — the code is
    // reported the way every Windows document writes it.
    test('reports the code the way Windows writes it', () {
      expect(
        () => checkHResult(_asHresult(0x80070057), 'ITaskFolder::GetTask'),
        throwsA(
          isA<AutostartOsException>()
              .having((e) => e.errorCode, 'errorCode', 0x80070057)
              .having((e) => e.detail, 'detail', contains('0x80070057')),
        ),
      );
    });

    test('names an unmapped code by its hex value alone', () {
      expect(
        () => checkHResult(_asHresult(0x80041318), 'ITaskFolder::Register'),
        throwsA(
          isA<AutostartOsException>()
              .having((e) => e.errorCode, 'errorCode', 0x80041318)
              .having((e) => e.detail, 'detail', 'HRESULT 0x80041318'),
        ),
      );
    });
  });

  group('reportsAbsent', () {
    test('accepts ERROR_FILE_NOT_FOUND', () {
      expect(reportsAbsent(_asHresult(0x80070002)), isTrue);
    });

    // The one that a first implementation misses. Task Scheduler answers with
    // this when an *intermediate* folder is missing, so a nested folder path
    // that is simply absent would otherwise throw out of a method documented as
    // answering a question.
    test('accepts ERROR_PATH_NOT_FOUND', () {
      expect(reportsAbsent(_asHresult(0x80070003)), isTrue);
    });

    test('rejects success and unrelated failures', () {
      expect(reportsAbsent(0), isFalse);
      expect(reportsAbsent(1), isFalse);
      expect(reportsAbsent(_asHresult(0x80070005)), isFalse);
      expect(reportsAbsent(_asHresult(0x80004002)), isFalse);
    });
  });

  // The release discipline is the claim this package is least able to observe:
  // a dropped `Release` leaks silently and no assertion anywhere turns red. So
  // these drive a **hand-built COM object** — a vtable of Dart functions that
  // counts which slot was called. It is not a fake standing in for the real
  // Task Scheduler; it is an instrument for reading a number the real one will
  // not report.
  group('release discipline', () {
    setUp(_resetFakeObjectCounters);

    test('comRelease calls slot 2 and not slot 1', () {
      using((arena) => comRelease(_fakeObject(arena)));

      expect(_releaseCalls, 1);
      expect(
        _addRefCalls,
        0,
        reason: 'slot 1 is AddRef and must not be called',
      );
    });

    test('comRelease ignores a null pointer', () {
      expect(() => comRelease(nullptr), returnsNormally);
      expect(_releaseCalls, 0);
    });

    // `comRelease` runs as an arena release callback, and `Arena.releaseAll`
    // abandons the rest of its list if a callback throws — so one raise here
    // would leak every interface still queued behind it. It has to be
    // infallible even on a pointer that is structurally broken.
    test('comRelease does not throw on an object with no vtable', () {
      using((arena) {
        final broken = arena<IntPtr>()..value = 0;

        expect(() => comRelease(broken), returnsNormally);
      });
    });

    test('comRelease does not throw when slot 2 holds no function', () {
      using((arena) {
        final table = arena<IntPtr>(3);
        table[2] = 0;
        final broken = arena<IntPtr>()..value = table.address;

        expect(() => comRelease(broken), returnsNormally);
      });
    });

    test('ownInterface releases when the arena closes', () {
      using((arena) => ownInterface(arena, _fakeObject(arena)));

      expect(_releaseCalls, 1);
    });

    // The failure path, which is the half a `try`/`finally` chain gets wrong.
    test('ownInterface releases when the body throws', () {
      expect(
        () => using((arena) {
          ownInterface(arena, _fakeObject(arena));
          throw StateError('boom');
        }),
        throwsStateError,
      );

      expect(_releaseCalls, 1);
    });

    test('releases every interface an arena owns', () {
      using((arena) {
        ownInterface(arena, _fakeObject(arena));
        ownInterface(arena, _fakeObject(arena));
        ownInterface(arena, _fakeObject(arena));
      });

      expect(_releaseCalls, 3);
    });
  });

  // `QueryInterface` is how this package upcasts an interface it was handed to
  // the one it means to call — and its whole value is that it *fails* when the
  // object is not what the code assumed. A version that ignored the HRESULT
  // would hand back a null pointer that looks like an interface.
  group('queryInterface', () {
    test('returns the interface an object does implement', () {
      withCom(() {
        using((arena) {
          final service = createInstance(
            arena,
            _clsidTaskScheduler,
            _iidTaskService,
          );

          expect(
            queryInterface(arena, service, _iidTaskService, 'QueryInterface'),
            isNot(nullptr),
          );
        });
      });
    });

    test('raises for an interface the object does not implement', () {
      withCom(() {
        using((arena) {
          final service = createInstance(
            arena,
            _clsidTaskScheduler,
            _iidTaskService,
          );

          expect(
            () => queryInterface(
              arena,
              service,
              'f2a82542-bda5-4e6b-9143-e2bf4f8987b6', // IID_IExecAction2
              'ITaskService::QueryInterface',
            ),
            throwsA(
              isA<AutostartOsException>()
                  .having((e) => e.errorCode, 'errorCode', 0x80004002)
                  .having((e) => e.message, 'message', contains('interface')),
            ),
          );
        });
      });
    });
  });

  group('withCom', () {
    test('returns what the body returns', () {
      expect(withCom(() => 'result'), 'result');
    });

    // The apartment is per-thread state that outlives any one call, so a
    // mismatched initialise/uninitialise pair does not fail here — it fails in
    // whatever runs next. Running the block twice, then nesting it, is what
    // catches an unbalanced pair.
    test('can be entered again after it has exited', () {
      expect(withCom(() => 1), 1);
      expect(withCom(() => 2), 2);
    });

    test('nests', () {
      expect(withCom(() => withCom(() => 'inner')), 'inner');
    });

    test('leaves the apartment balanced when the body throws', () {
      expect(() => withCom(() => throw StateError('boom')), throwsStateError);

      expect(withCom(() => 'still works'), 'still works');
    });

    // Every claim above is about *who owns the apartment*, and none of them can
    // be read from `withCom`'s own return value. These two ask the question
    // through `CoInitializeEx` directly — bound in this file, so the observer is
    // not the code under test.

    test('gives back the apartment it took', () {
      withCom(() => null);

      // Nothing else initialised COM on this thread, so if `withCom` had kept
      // its reference this would report S_FALSE — "already up" — instead of
      // taking a fresh one.
      final hr = _coInitializeEx(nullptr, _coinitMultithreaded);
      addTearDown(_coUninitialize);
      expect(hr, 0, reason: 'S_FALSE here would mean withCom never released');
    });

    // The host-initialised case. `CoInitializeEx` fails with
    // `RPC_E_CHANGED_MODE` when the thread is already in the other apartment,
    // and that failure takes no reference — so uninitialising after it would
    // tear down an apartment the host owns. Any program that set up COM before
    // calling this package depends on that distinction.
    test('leaves an apartment it did not take alone', () {
      expect(
        _coInitializeEx(nullptr, _coinitApartmentThreaded),
        0,
        reason:
            'this test has to own the apartment for the check to mean '
            'anything',
      );

      try {
        withCom(() => null);

        // Still ours: a second initialise reports "already up" rather than
        // taking a fresh reference, which it could not do if `withCom` had
        // uninitialised on our behalf.
        expect(
          _coInitializeEx(nullptr, _coinitApartmentThreaded),
          1,
          reason: 'S_OK here would mean withCom tore down our apartment',
        );
        _coUninitialize();
      } finally {
        _coUninitialize();
      }
    });

    // `T` binds to `Future` as happily as to anything else, so this is the one
    // rule the type system cannot carry: an `async` body would return at its
    // first `await`, the apartment would close immediately, and every COM
    // release the body arranged would then run against a thread that has none.
    test('refuses an asynchronous body', () {
      expect(
        () => withCom(() async => 'nope'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('synchronous'),
          ),
        ),
      );
    });
  });
}

/// Reinterprets an unsigned HRESULT literal as the signed 32-bit value the ABI
/// actually returns.
int _asHresult(int unsigned) => unsigned.toSigned(32);

// --- A hand-built COM object -------------------------------------------------

int _addRefCalls = 0;
int _releaseCalls = 0;

void _resetFakeObjectCounters() {
  _addRefCalls = 0;
  _releaseCalls = 0;
}

int _countAddRef(ComPtr self) => ++_addRefCalls;

int _countRelease(ComPtr self) => ++_releaseCalls;

final _addRef = NativeCallable<Uint32 Function(ComPtr)>.isolateLocal(
  _countAddRef,
  exceptionalReturn: 0,
);

final _release = NativeCallable<Uint32 Function(ComPtr)>.isolateLocal(
  _countRelease,
  exceptionalReturn: 0,
);

/// An object shaped exactly like a COM interface pointer: one word pointing at
/// a vtable whose slots 1 and 2 are `AddRef` and `Release`.
///
/// Slot 0 is left null on purpose. `QueryInterface` is never reached by
/// anything under test here, and a null there means a mistake that did reach it
/// would fail loudly rather than call something plausible.
ComPtr _fakeObject(Arena arena) {
  final vtable = arena<IntPtr>(3);
  vtable[0] = 0;
  vtable[1] = _addRef.nativeFunction.address;
  vtable[2] = _release.nativeFunction.address;

  return arena<IntPtr>()..value = vtable.address;
}

// --- COM initialisation, bound here so the observer is not the code under test

final _ole32 = loadKnownDll('ole32.dll');

final _coInitializeEx = _ole32
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('CoInitializeEx');

final _coUninitialize = _ole32.lookupFunction<Void Function(), void Function()>(
  'CoUninitialize',
);

const int _coinitMultithreaded = 0x0;
const int _coinitApartmentThreaded = 0x2;

/// `VT_BSTR`. Not in `com.dart`, which has no production use for it — it exists
/// here because a variant carrying something is the only way to prove an empty
/// one is being passed correctly.
const int _vtBstr = 8;

const String _clsidTaskScheduler = '0f87369f-a4e5-4cfc-bd3e-73e6154572dd';
const String _iidTaskService = '2faba4c7-4da9-4013-9697-20cc3fd40f85';
