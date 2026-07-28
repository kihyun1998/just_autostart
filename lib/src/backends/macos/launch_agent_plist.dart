import '../../exceptions.dart';
import '../../list_equals.dart';

/// A launchd user-agent property list this package wrote, split back into the
/// pieces it was built from.
///
/// The analogue of the Windows `RunCommandLine`: launchd keeps the executable
/// and its arguments in one `ProgramArguments` array whose first element is the
/// program, so this decodes that shape into a path and a separate argument list.
final class LaunchAgentPlist {
  /// Creates a decoded plist.
  const LaunchAgentPlist({
    required this.label,
    required this.executablePath,
    required this.args,
    required this.runAtLoad,
    required this.disabled,
  });

  /// The launchd job label, which also names the file on disk.
  final String label;

  /// The executable the agent launches — `ProgramArguments[0]`.
  final String executablePath;

  /// The arguments passed to it — `ProgramArguments[1..]`.
  final List<String> args;

  /// Whether `RunAtLoad` is set — launchd starts the job once when it loads,
  /// which for a user agent is at login. `false` (the launchd default when the
  /// key is absent) means the agent loads but does not start the program.
  final bool runAtLoad;

  /// Whether the in-plist `Disabled` key is `true`.
  ///
  /// This is a *second* store inside the same file: a plist can exist, name the
  /// right program, and still be skipped at login because this key is set — the
  /// "existence is not enablement" hazard appearing inside the file the parser
  /// already reads. It is distinct from launchd's root-owned disable overrides,
  /// which live outside the plist.
  final bool disabled;

  @override
  bool operator ==(Object other) =>
      other is LaunchAgentPlist &&
      other.label == label &&
      other.executablePath == executablePath &&
      listEquals(other.args, args) &&
      other.runAtLoad == runAtLoad &&
      other.disabled == disabled;

  @override
  int get hashCode => Object.hash(
    label,
    executablePath,
    Object.hashAll(args),
    runAtLoad,
    disabled,
  );

  @override
  String toString() =>
      'LaunchAgentPlist(label: $label, executablePath: $executablePath, '
      'args: $args, runAtLoad: $runAtLoad, disabled: $disabled)';
}

/// Builds the launchd user-agent plist that starts [executablePath] at login.
///
/// The keys follow `launchd.plist(5)`: `Label` names the job, `ProgramArguments`
/// is an array whose first element is the program and whose rest are its
/// arguments, and `RunAtLoad` makes launchd start it once when the agent is
/// loaded — which for a user agent happens at login, with no `launchctl` call.
///
/// Every string value is XML-escaped. A raw `<` or `&` in a path or argument
/// would make the document not well-formed, and launchd's failure mode for a
/// malformed plist is to ignore it silently at the next login — a defect that is
/// invisible on the developer's machine and appears only at a user's login.
String generateLaunchAgentPlist({
  required String label,
  required String executablePath,
  required List<String> args,
  bool runAtLoad = true,
}) {
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    )
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>')
    ..writeln('\t<key>Label</key>')
    ..writeln('\t<string>${_escape(label)}</string>')
    ..writeln('\t<key>ProgramArguments</key>')
    ..writeln('\t<array>')
    ..writeln('\t\t<string>${_escape(executablePath)}</string>');
  for (final arg in args) {
    buffer.writeln('\t\t<string>${_escape(arg)}</string>');
  }
  buffer
    ..writeln('\t</array>')
    ..writeln('\t<key>RunAtLoad</key>')
    ..writeln('\t${runAtLoad ? '<true/>' : '<false/>'}')
    ..writeln('</dict>')
    ..writeln('</plist>');
  return buffer.toString();
}

/// Reads a launchd user-agent plist back into its label, executable, and args.
///
/// Tolerates plists this package did not write: keys it does not recognise are
/// ignored, so a plist from an earlier version or one hand-edited by the user is
/// not destroyed on an upgrade. Only `Label`, `ProgramArguments`, `RunAtLoad`,
/// and `Disabled` are read — the keys that decide identity and whether the job
/// starts at login.
///
/// Throws [MalformedRegistrationException] when the document is not well-formed
/// enough to yield those two keys, or when the program array is empty. The plist
/// sits at a path derived from this package's own `label`, so a corrupt one is
/// this application's broken registration — an error to surface — not a foreign
/// entry to leave alone (contrast the Windows `Run` key, a shared namespace
/// where an unrecognised value is returned as `null`).
LaunchAgentPlist parseLaunchAgentPlist(String xml) {
  // Comments are stripped first so a commented-out `<key>…</key>` before the
  // real one cannot be the value a first-match scan returns. A regex is not an
  // XML parser, and this is the one XML construct that would otherwise let it
  // read the wrong element out of a hand-edited plist.
  final body = xml.replaceAll(RegExp('<!--.*?-->', dotAll: true), '');

  final label = _stringForKey(body, 'Label');
  final program = _stringArrayForKey(body, 'ProgramArguments');

  if (label == null) {
    throw const MalformedRegistrationException('no Label string');
  }
  if (program == null) {
    throw const MalformedRegistrationException('no ProgramArguments array');
  }
  if (program.isEmpty) {
    throw const MalformedRegistrationException(
      'ProgramArguments names no executable',
    );
  }

  return LaunchAgentPlist(
    label: label,
    executablePath: program.first,
    args: List.unmodifiable(program.skip(1)),
    runAtLoad: _boolForKey(body, 'RunAtLoad'),
    disabled: _boolForKey(body, 'Disabled'),
  );
}

/// Finds `<key>NAME</key>` and returns the `<string>` that follows it.
///
/// Whitespace between the key and its value is tolerated, so hand-authored
/// formatting parses. Returns `null` when the pair is not present — which
/// includes a truncated document where the closing tags never arrive, so a
/// not-well-formed plist falls through to the malformed check rather than
/// needing a separate XML validator.
///
/// A repeated key resolves to the **last** occurrence, matching Apple's
/// `CFPropertyList` — which is what launchd reads the file with — verified
/// against `plutil`. Reporting the first would let `isEnabled()` disagree with
/// what actually launches after a hand-edit that appended a fresh block.
String? _stringForKey(String xml, String key) {
  final matches = RegExp(
    '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>(.*?)</string>',
    dotAll: true,
  ).allMatches(xml);
  if (matches.isEmpty) return null;
  return _unescape(matches.last.group(1)!);
}

/// Finds `<key>NAME</key>` and returns the strings inside the `<array>` after it.
///
/// Returns `null` when the key-then-array pair is not present. An array with no
/// `<string>` elements returns an empty list, which the caller rejects. A
/// repeated key resolves to the last occurrence (see [_stringForKey]).
List<String>? _stringArrayForKey(String xml, String key) {
  final arrayMatches = RegExp(
    '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<array>(.*?)</array>',
    dotAll: true,
  ).allMatches(xml);
  if (arrayMatches.isEmpty) return null;

  return RegExp('<string>(.*?)</string>', dotAll: true)
      .allMatches(arrayMatches.last.group(1)!)
      .map((m) => _unescape(m.group(1)!))
      .toList();
}

/// Reads a boolean-valued key, returning `true` only for an explicit `<true/>`.
///
/// A missing key, or `<false/>`, is `false` — which matches launchd's default
/// for both `RunAtLoad` and `Disabled`. A repeated key resolves to the last
/// occurrence (see [_stringForKey]).
bool _boolForKey(String xml, String key) {
  final matches = RegExp(
    '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<(true|false)\\s*/>',
    dotAll: true,
  ).allMatches(xml);
  return matches.isNotEmpty && matches.last.group(1) == 'true';
}

// Element content only needs `&`, `<`, and `>` escaped; quotes are literal
// inside a `<string>` element. Ampersand goes first so the entities this
// introduces are not re-escaped.
String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

// The inverse. The named entities are replaced before `&amp;` so a literal
// "&lt;" written as "&amp;lt;" survives. Only the five named entities are
// decoded — the characters this package escapes on the way out, plus the quote
// forms a hand-written plist might use. Numeric character references
// (`&#38;`) are *not* decoded; the writers this reads back from — this package
// and Apple's own serialiser — emit named entities for these characters.
String _unescape(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
