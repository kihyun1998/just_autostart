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
