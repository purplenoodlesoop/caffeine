// ── Snapshot ──────────────────────────────────────────────────────────────────

abstract interface class Snapshot<T> {
  /// Last computed value of this node, without registering a dependency.
  T? get current;

  /// Reads [state] and registers it as a dependency of the current computation.
  A call<A>(Stateful<A> state);
}

// ── Stateful ──────────────────────────────────────────────────────────────────

/// An immutable description of a reactive derived value.
///
/// Holds only the pure computation — no mutable state. All runtime state
/// (cached value, stale flag, dependency graph, stream controller) lives in
/// the [Scope] that evaluates it.
class Stateful<S> {
  const Stateful(this.body);

  final S Function(Snapshot<S> $) body;
}
