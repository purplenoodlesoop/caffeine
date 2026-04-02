import 'package:meta/meta.dart';

import 'event.dart';
import 'override.dart';

// ── StoreOverride ─────────────────────────────────────────────────────────────

final class MappingStoreOverride<T> implements StoreOverride {
  final Store<T> from;
  final Store<T> to;

  const MappingStoreOverride({required this.from, required this.to});
}

// ── StateSource ───────────────────────────────────────────────────────────────

abstract interface class StateSource {
  T read<T>(Store<T> node, {bool listen});
}

extension StateSourceX<T> on Store<T> {
  T call(StateSource source, {bool listen = true}) =>
      source.read(this, listen: listen);
}

// ── StoreState / StoreAcc ─────────────────────────────────────────────────────

abstract interface class StoreState<S> {
  S get current;

  void on<E>(Event<E> event, Stream<S> Function(E) update);
}

abstract interface class StoreAcc<T>
    implements StoreState<T>, EventSource, StateSource {}

// ── Typedefs ──────────────────────────────────────────────────────────────────

typedef DerivedStoreBody<T> = T Function(StateSource source);
typedef AccumStoreBody<T> = T Function(StoreAcc<T> source);

// ── Store ─────────────────────────────────────────────────────────────────────

abstract interface class Store<T> implements StoreOverride, Event<T> {
  const factory Store.derive(DerivedStoreBody<T> body) = _DerivedStore;
  const factory Store.accum(AccumStoreBody<T> body) = _AccumStore;

  /// Calls [callback] with the concrete type parameter of this store,
  /// recovering [T] for typed initialization inside the scope.
  @internal
  void callTyped(void Function<T2>(Store<T2>) callback);
}

// ── Private implementations ───────────────────────────────────────────────────

final class _DerivedStore<T> implements Store<T> {
  const _DerivedStore(this.body);

  final DerivedStoreBody<T> body;

  @override
  void callTyped(void Function<T2>(Store<T2>) callback) => callback<T>(this);
}

final class _AccumStore<T> implements Store<T> {
  const _AccumStore(this.body);

  final AccumStoreBody<T> body;

  @override
  void callTyped(void Function<T2>(Store<T2>) callback) => callback<T>(this);
}

// ── Internal accessors (used by scope only) ───────────────────────────────────

extension StoreInternals<T> on Store<T> {
  bool get isDerived => this is _DerivedStore<T>;
  bool get isAccum => this is _AccumStore<T>;

  DerivedStoreBody<T> get derivedBody => (this as _DerivedStore<T>).body;
  AccumStoreBody<T> get accumBody => (this as _AccumStore<T>).body;
}
