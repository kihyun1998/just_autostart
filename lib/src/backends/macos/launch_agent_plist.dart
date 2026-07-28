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
    this.keepAlive,
    this.standardOutPath,
    this.standardErrorPath,
    this.workingDirectory,
    this.environment = const {},
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

  /// Whether launchd restarts the program when it exits, or `null` when the
  /// key is absent and launchd's own default (do not restart) applies.
  ///
  /// Nullable rather than defaulted, because "the caller said false" and "the
  /// caller said nothing" are different registrations: the first writes the key
  /// and the second leaves launchd to decide.
  final bool? keepAlive;

  /// Where the program's standard output is written, or `null` when unset.
  final String? standardOutPath;

  /// Where the program's standard error is written, or `null` when unset.
  final String? standardErrorPath;

  /// The directory launchd changes to before running the program, or `null`.
  final String? workingDirectory;

  /// Environment variables set for the launched process; empty when unset.
  final Map<String, String> environment;

  @override
  bool operator ==(Object other) =>
      other is LaunchAgentPlist &&
      other.label == label &&
      other.executablePath == executablePath &&
      listEquals(other.args, args) &&
      other.runAtLoad == runAtLoad &&
      other.disabled == disabled &&
      other.keepAlive == keepAlive &&
      other.standardOutPath == standardOutPath &&
      other.standardErrorPath == standardErrorPath &&
      other.workingDirectory == workingDirectory &&
      mapEquals(other.environment, environment);

  @override
  int get hashCode => Object.hash(
    label,
    executablePath,
    Object.hashAll(args),
    runAtLoad,
    disabled,
    keepAlive,
    standardOutPath,
    standardErrorPath,
    workingDirectory,
    Object.hashAllUnordered(environment.keys),
  );

  @override
  String toString() =>
      'LaunchAgentPlist(label: $label, executablePath: $executablePath, '
      'args: $args, runAtLoad: $runAtLoad, disabled: $disabled, '
      'keepAlive: $keepAlive, standardOutPath: $standardOutPath, '
      'standardErrorPath: $standardErrorPath, '
      'workingDirectory: $workingDirectory, environment: $environment)';
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
  bool? keepAlive,
  String? standardOutPath,
  String? standardErrorPath,
  String? workingDirectory,
  Map<String, String> environment = const {},
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
    ..writeln('\t${runAtLoad ? '<true/>' : '<false/>'}');

  // Every optional key is emitted only when the caller supplied it, so a
  // caller who configures nothing gets the same minimal agent as before and
  // launchd applies its own defaults rather than ours.
  if (keepAlive != null) {
    buffer
      ..writeln('\t<key>KeepAlive</key>')
      ..writeln('\t${keepAlive ? '<true/>' : '<false/>'}');
  }
  if (standardOutPath != null) {
    buffer
      ..writeln('\t<key>StandardOutPath</key>')
      ..writeln('\t<string>${_escape(standardOutPath)}</string>');
  }
  if (standardErrorPath != null) {
    buffer
      ..writeln('\t<key>StandardErrorPath</key>')
      ..writeln('\t<string>${_escape(standardErrorPath)}</string>');
  }
  if (workingDirectory != null) {
    buffer
      ..writeln('\t<key>WorkingDirectory</key>')
      ..writeln('\t<string>${_escape(workingDirectory)}</string>');
  }
  if (environment.isNotEmpty) {
    buffer
      ..writeln('\t<key>EnvironmentVariables</key>')
      ..writeln('\t<dict>');
    for (final entry in environment.entries) {
      // A variable's name is caller data too, so both halves are escaped.
      buffer
        ..writeln('\t\t<key>${_escape(entry.key)}</key>')
        ..writeln('\t\t<string>${_escape(entry.value)}</string>');
    }
    buffer.writeln('\t</dict>');
  }

  buffer
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

  // Top-level keys are read from the outer dict's *own* entries. A nested dict
  // — `EnvironmentVariables` is one — holds caller-supplied names in `<key>`
  // elements, and scanning the whole document would let a variable called
  // `Label` or `StandardOutPath` shadow the real key. `Label` is the dangerous
  // one: `disable()` decides whether a plist belongs to this application by
  // that value.
  final top = _topLevelDictBody(body);

  final label = _stringForKey(top, 'Label');
  final program = _stringArrayForKey(top, 'ProgramArguments');

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
    runAtLoad: _boolForKey(top, 'RunAtLoad'),
    disabled: _boolForKey(top, 'Disabled'),
    keepAlive: _optionalBoolForKey(top, 'KeepAlive'),
    standardOutPath: _stringForKey(top, 'StandardOutPath'),
    standardErrorPath: _stringForKey(top, 'StandardErrorPath'),
    workingDirectory: _stringForKey(top, 'WorkingDirectory'),
    environment: Map.unmodifiable(
      _stringDictForKey(body, 'EnvironmentVariables') ?? const {},
    ),
  );
}

/// The outer `<dict>`'s own entries, with every nested dict's contents removed.
///
/// A plain scan for `<key>NAME</key>` cannot tell a top-level key from one
/// inside `EnvironmentVariables`, whose names come from the caller. Keeping only
/// what sits at nesting depth one makes "top-level key" mean what it says, so a
/// variable cannot impersonate `Label`, `StandardOutPath`, or any other key the
/// backend acts on.
///
/// Depth is counted rather than matched by regex because the nesting is
/// arbitrary in a plist this package did not write. A self-closing `<dict/>`
/// opens and closes at once and so changes nothing.
String _topLevelDictBody(String xml) {
  const open = '<dict>';
  const close = '</dict>';
  const empty = '<dict/>';

  final buffer = StringBuffer();
  var depth = 0;
  var i = 0;

  while (i < xml.length) {
    if (xml.startsWith(empty, i)) {
      i += empty.length;
      continue;
    }
    if (xml.startsWith(open, i)) {
      depth++;
      i += open.length;
      continue;
    }
    if (xml.startsWith(close, i)) {
      depth--;
      i += close.length;
      continue;
    }
    if (depth == 1) buffer.write(xml[i]);
    i++;
  }

  return buffer.toString();
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
bool _boolForKey(String xml, String key) =>
    _optionalBoolForKey(xml, key) ?? false;

/// Reads a boolean-valued key, distinguishing absent (`null`) from `<false/>`.
///
/// The distinction matters for keys where launchd's own default is not the same
/// as an explicit false — and, more simply, because writing back what was read
/// has to reproduce the original document.
bool? _optionalBoolForKey(String xml, String key) {
  final matches = RegExp(
    '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<(true|false)\\s*/>',
    dotAll: true,
  ).allMatches(xml);
  if (matches.isEmpty) return null;
  return matches.last.group(1) == 'true';
}

/// Finds `<key>NAME</key>` and returns the `<key>`/`<string>` pairs inside the
/// `<dict>` that follows it, or `null` when the pair is not present.
///
/// Only string-valued entries are read: that is what this package writes, and a
/// foreign entry of another type is skipped rather than making the whole plist
/// unreadable. A repeated key resolves to the last occurrence (see
/// [_stringForKey]).
Map<String, String>? _stringDictForKey(String xml, String key) {
  final dictMatches = RegExp(
    '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<dict>(.*?)</dict>',
    dotAll: true,
  ).allMatches(xml);
  if (dictMatches.isEmpty) return null;

  final entries = <String, String>{};
  final pairs = RegExp(
    '<key>(.*?)</key>\\s*<string>(.*?)</string>',
    dotAll: true,
  ).allMatches(dictMatches.last.group(1)!);
  for (final pair in pairs) {
    entries[_unescape(pair.group(1)!)] = _unescape(pair.group(2)!);
  }
  return entries;
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
