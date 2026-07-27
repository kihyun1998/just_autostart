import '../../list_equals.dart';

/// A command line this package wrote into the registry `Run` key, split back
/// into the pieces it was built from.
final class RunCommandLine {
  /// Creates a decoded command line.
  const RunCommandLine({required this.executablePath, required this.args});

  /// The executable the entry launches.
  final String executablePath;

  /// The arguments passed to it.
  final List<String> args;

  @override
  bool operator ==(Object other) =>
      other is RunCommandLine &&
      other.executablePath == executablePath &&
      listEquals(other.args, args);

  @override
  int get hashCode => Object.hash(executablePath, Object.hashAll(args));

  @override
  String toString() =>
      'RunCommandLine(executablePath: $executablePath, args: $args)';
}

/// Builds the single string the registry `Run` key stores for an entry.
///
/// Windows parses that string with its own rules — the same ones
/// `CommandLineToArgvW` implements — so the encoding here is not cosmetic.
///
/// The executable path is quoted **unconditionally**. Quoting it only when it
/// contains a space is the bug class where an entry works on the developer's
/// machine and silently launches nothing on a user whose install directory is
/// `C:\Program Files\…`; `launch_at_startup` has exactly that defect
/// (`docs/agents/lessons.md` #3). Unconditional quoting also makes the encoding
/// *canonical*, which is what lets [decodeRunCommandLine] recognise the entries
/// this package owns.
String encodeRunCommandLine(String executablePath, List<String> args) {
  // The first token is special to CommandLineToArgvW: when it starts with a
  // quote it runs to the next quote with no escape processing at all. So the
  // path goes in verbatim rather than through _quoteArgument.
  final buffer = StringBuffer('"')
    ..write(executablePath)
    ..write('"');
  if (args.isNotEmpty) {
    buffer
      ..write(' ')
      ..write(encodeArguments(args));
  }
  return buffer.toString();
}

/// Builds the argument tail on its own, without a leading executable.
///
/// A scheduled task keeps the executable and its arguments in **two** fields —
/// `IExecAction`'s `Path` and `Arguments` — where the `Run` key has one string.
/// The quoting rules are the same either way, because the same
/// `CommandLineToArgvW` parses what the task launches, so this shares
/// [encodeRunCommandLine]'s implementation rather than restating it. Two copies
/// of these rules is how the two mechanisms would come to disagree about what a
/// caller's arguments mean.
String encodeArguments(List<String> args) => args.map(_quoteArgument).join(' ');

/// Splits an argument tail back into the values it was built from.
///
/// Returns `null` on an unterminated quote, which is the only input Windows
/// itself would refuse. Unlike [decodeRunCommandLine] there is no canonical
/// form to recognise here: an empty tail is a real, valid answer — a program
/// registered with no arguments — not a failure to parse.
List<String>? decodeArguments(String value) => _parseArguments(value);

/// Splits a registry `Run` value back into an executable path and arguments.
///
/// Returns `null` when [value] is **not** in the canonical form
/// [encodeRunCommandLine] produces — an unquoted path, an unterminated quote, an
/// empty path. That is the point rather than a limitation: this package always
/// quotes, so anything that fails to decode was written by something else.
///
/// Both call sites depend on it. `isEnabled()` reports false for an entry it
/// does not recognise, and `disable()` leaves such an entry alone instead of
/// deleting a third party's autostart out of a shared namespace.
RunCommandLine? decodeRunCommandLine(String value) {
  final trimmed = value.trim();
  if (!trimmed.startsWith('"')) return null;

  final closing = trimmed.indexOf('"', 1);
  if (closing < 0) return null;

  final executablePath = trimmed.substring(1, closing);
  if (executablePath.isEmpty) return null;

  final args = _parseArguments(trimmed.substring(closing + 1));
  if (args == null) return null;

  return RunCommandLine(
    executablePath: executablePath,
    args: List.unmodifiable(args),
  );
}

bool _needsQuoting(String arg) =>
    arg.isEmpty ||
    arg.contains(' ') ||
    arg.contains('\t') ||
    arg.contains('\n') ||
    arg.contains('\v') ||
    arg.contains('"');

String _quoteArgument(String arg) {
  if (!_needsQuoting(arg)) return arg;

  final buffer = StringBuffer('"');
  for (var i = 0; i < arg.length;) {
    var backslashes = 0;
    while (i < arg.length && arg[i] == r'\') {
      backslashes++;
      i++;
    }

    if (i == arg.length) {
      // Backslashes immediately before the closing quote would escape it, so
      // they are doubled. Interior ones are left alone — a backslash is only an
      // escape character when a quote follows it.
      buffer.write(r'\' * (backslashes * 2));
      break;
    }

    if (arg[i] == '"') {
      buffer
        ..write(r'\' * (backslashes * 2 + 1))
        ..write('"');
    } else {
      buffer
        ..write(r'\' * backslashes)
        ..write(arg[i]);
    }
    i++;
  }
  return (buffer..write('"')).toString();
}

/// The inverse of [_quoteArgument] across a whole tail, following
/// `CommandLineToArgvW`. Returns `null` on an unterminated quote.
List<String>? _parseArguments(String tail) {
  final args = <String>[];
  var i = 0;

  while (i < tail.length) {
    while (i < tail.length && (tail[i] == ' ' || tail[i] == '\t')) {
      i++;
    }
    if (i >= tail.length) break;

    final buffer = StringBuffer();
    var inQuotes = false;
    var started = false;

    while (i < tail.length) {
      final char = tail[i];

      if (char == r'\') {
        var backslashes = 0;
        while (i < tail.length && tail[i] == r'\') {
          backslashes++;
          i++;
        }
        if (i < tail.length && tail[i] == '"') {
          buffer.write(r'\' * (backslashes ~/ 2));
          if (backslashes.isOdd) {
            buffer.write('"');
          } else {
            inQuotes = !inQuotes;
          }
          i++;
        } else {
          buffer.write(r'\' * backslashes);
        }
        started = true;
      } else if (char == '"') {
        inQuotes = !inQuotes;
        started = true;
        i++;
      } else if (!inQuotes && (char == ' ' || char == '\t')) {
        break;
      } else {
        buffer.write(char);
        started = true;
        i++;
      }
    }

    if (inQuotes) return null;
    if (started) args.add(buffer.toString());
  }

  return args;
}
