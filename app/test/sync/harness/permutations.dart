/// Every ordering of a list, for the order-independence assertions.
///
/// Shared by the golden-vector runner (cases carrying `permute`) and by the
/// merge-strategy lattice laws, which make the same claim at different grain:
/// one copy per suite is how two statements of one property drift apart.
///
/// Callers keep their input small — three ops is six orders — so the factorial
/// blow-up is bounded by review rather than by code.
library;

List<List<T>> permutations<T>(List<T> items) {
  if (items.length <= 1) return [List<T>.of(items)];
  final result = <List<T>>[];
  for (var index = 0; index < items.length; index++) {
    final rest = [...items]..removeAt(index);
    for (final tail in permutations(rest)) {
      result.add([items[index], ...tail]);
    }
  }
  return result;
}
