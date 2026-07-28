/// Whether [a] and [b] hold equal elements in the same order.
///
/// Hand-rolled rather than pulled from `package:collection`: this package's
/// dependency story is "`package:ffi` on Windows and nothing else", and one
/// nine-line loop is a cheaper price than a second runtime dependency.
bool listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Whether [a] and [b] hold the same keys mapped to the same values.
///
/// Order is not part of a map's identity, so this compares by lookup rather
/// than by iteration order. Same reasoning as [listEquals] for why it is
/// hand-rolled.
bool mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
