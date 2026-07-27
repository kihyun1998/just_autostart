/// A probe the window-visibility test registers as a scheduled task.
///
/// It is run **by Task Scheduler**, not by the test process, and writes what it
/// sees to the file named by its first argument. That indirection is the whole
/// design: whether the console window appears is decided by the
/// `STARTUPINFO.wShowWindow` the *launcher* passes, so nothing measured inside
/// the test process can answer the question.
///
/// It reports `IsWindowVisible(GetConsoleWindow())` and **not**
/// `GetConsoleWindow() != 0`. A hidden console still has a window handle, so
/// the second question reads `true` for every mechanism and answers nothing —
/// `docs/agents/lessons.md` #9 is that mistake.
library;

import 'dart:ffi';
import 'dart:io';

void main(List<String> args) {
  final console = _getConsoleWindow();
  final visible = console.address != 0 && _isWindowVisible(console) != 0;

  File(args.first).writeAsStringSync(
    'hasConsole=${console.address != 0} visible=$visible',
    flush: true,
  );
}

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _getConsoleWindow = _kernel32
    .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
      'GetConsoleWindow',
    );

final _isWindowVisible = _user32
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'IsWindowVisible',
    );
