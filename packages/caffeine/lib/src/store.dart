import 'package:meta/meta.dart';

import 'event.dart';
import 'override.dart';

/// Substitutes one store for another within a [Scope]'s subtree. Any read of
/// [from] is transparently resolved to [to]. Used for dependency injection
/// and testing.
final class MappingStoreOverride<T> implements StoreOverride {
  const MappingStoreOverride({required this.from, required this.to});

  final Store<T> from;
  final Store<T> to;
}

/// Read API exposed inside a [Store.derive] body. Every read tracked here
/// becomes a dependency of the derived store; the body is automatically
/// recomputed whenever a dependency changes.
///
/// Pass `listen: false` for a one-shot read that does *not* register a
/// dependency — the body will not recompute on that store's changes.
abstract interface class StateSource {
  T read<T>(Store<T> node, {bool listen = true});
}

/// Sugar: `someStore(source)` is short for `source.read(someStore)`. Inside a
/// derived body, the read is tracked as a dependency unless `listen: false`
/// is passed. Outside a derived body (e.g. on a [Scope] or [StoreAcc]), the
/// listen parameter has no effect — passing `listen: false` there throws.
extension StateSourceX<T> on Store<T> {
  T call(StateSource source, {bool listen = true}) =>
      source.read(this, listen: listen);
}

/// Concurrency strategy for an event handler registered via [StoreState.on].
///
/// Each strategy controls what happens when an event fires while a previous
/// invocation of its handler is still emitting states:
///
/// - [parallel] (default): every invocation runs concurrently; their `yield`s
///   interleave in arrival order. Preserves caffeine ≤ 2 semantics.
/// - [drop]: while an invocation is in flight, additional events for the same
///   handler are dropped. Useful for "throttle until first completes".
/// - [restart]: the prior invocation is cancelled and replaced. Useful for
///   debounced async work like search queries.
/// - [queue]: invocations are serialized; each waits for the previous to
///   complete before starting. Useful for ordered side effects.
enum Concurrency { parallel, drop, restart, queue }

/// Context exposed to a [Store.accum] body. Lets the body declare event
/// handlers, fire events, read other stores, and register dispose callbacks.
abstract interface class StoreState<S> {
  /// The current value of this store.
  S get current;

  /// Registers a handler that runs whenever [event] is dispatched. The
  /// handler returns a [Stream] of new states; each emitted state replaces
  /// [current] and triggers downstream propagation.
  ///
  /// Throws [StateError] if a handler is already registered for [event] on
  /// this store — silent overwrites are a common refactor footgun.
  ///
  /// See [Concurrency] for behavior when [event] fires while a prior
  /// invocation is still emitting.
  void on<E>(
    Event<E> event,
    Stream<S> Function(E) update, {
    Concurrency concurrency = Concurrency.parallel,
  });

  /// Registers a callback to run when the scope owning this store is
  /// disposed. Use to clean up external resources opened by the body
  /// (timers, sockets, external [StreamSubscription]s).
  void onDispose(void Function() callback);
}

/// Accum store context: combines [StoreState] (handler registration + dispose
/// hooks), [EventSource] (firing follow-on events), and [StateSource]
/// (reading other stores).
abstract interface class StoreAcc<T>
    implements StoreState<T>, EventSource, StateSource {}

typedef DerivedStoreBody<T> = T Function(StateSource source);
typedef AccumStoreBody<T> = T Function(StoreAcc<T> source);

/// A reactive value of type [T].
///
/// Two flavors:
///
/// - [Store.derive] — lazy derived value. Its body is a pure function over a
///   [StateSource]; every read inside the body registers a dependency, and
///   the value is recomputed automatically when a dependency changes.
///   Recomputation is glitch-free: diamond-shaped dependency graphs evaluate
///   each downstream node at most once per propagation cycle.
///
/// - [Store.accum] — event-driven stateful store. Its body runs once at scope
///   init and registers event handlers via `ctx.on(event, handler)`. State
///   transitions only happen in response to dispatched events.
///
/// Stores have identity — two `Store` instances are equal only by reference.
/// Don't construct a store inside a build/render function unless you mean to
/// create a new identity each time.
abstract interface class Store<T> implements StoreOverride {
  /// Creates a lazy derived store. [body] is called whenever a recorded
  /// dependency changes; the most recent return value is cached.
  ///
  /// [debugLabel] is included in error messages and diagnostics. [equals], if
  /// provided, replaces `==` for change detection — useful for collection
  /// types where structural equality is intended.
  const factory Store.derive(
    DerivedStoreBody<T> body, {
    String? debugLabel,
    bool Function(T, T)? equals,
  }) = _DerivedStore;

  /// Creates an accum store. [body] runs once at scope init; use the
  /// [StoreAcc] context to register `on(event, handler)` clauses, fire
  /// follow-on events, and (optionally) register `onDispose` cleanup.
  ///
  /// [debugLabel] is included in error messages. [equals], if provided,
  /// replaces `==` for change detection.
  const factory Store.accum(
    AccumStoreBody<T> body, {
    String? debugLabel,
    bool Function(T, T)? equals,
  }) = _AccumStore;

  /// Calls [callback] with the concrete type parameter of this store,
  /// recovering [T] for typed initialization inside the scope.
  @internal
  void callTyped(void Function<T2>(Store<T2>) callback);

  /// Diagnostic label, or `null` if none was provided.
  String? get debugLabel;
}

/// Sugar: declare a slice of a store without writing a full `Store.derive`.
///
/// ```dart
/// final user = Store<User>.accum(...);
/// final userName = user.select((u) => u.name);
/// ```
///
/// Returns a fresh derived store each call — call at top level, not inside a
/// build or render function (each call would otherwise create a new identity).
extension StoreSelectX<T> on Store<T> {
  Store<R> select<R>(
    R Function(T) selector, {
    String? debugLabel,
    bool Function(R, R)? equals,
  }) =>
      Store<R>.derive(
        (s) => selector(this(s)),
        debugLabel: debugLabel,
        equals: equals,
      );
}

// ── Private implementations ───────────────────────────────────────────────────

final class _DerivedStore<T> implements Store<T> {
  const _DerivedStore(this.body, {this.debugLabel, this.equals});

  final DerivedStoreBody<T> body;

  @override
  final String? debugLabel;

  final bool Function(T, T)? equals;

  @override
  void callTyped(void Function<T2>(Store<T2>) callback) => callback<T>(this);

  @override
  String toString() =>
      debugLabel != null ? 'Store.derive<$T>($debugLabel)' : 'Store.derive<$T>';
}

final class _AccumStore<T> implements Store<T> {
  const _AccumStore(this.body, {this.debugLabel, this.equals});

  final AccumStoreBody<T> body;

  @override
  final String? debugLabel;

  final bool Function(T, T)? equals;

  @override
  void callTyped(void Function<T2>(Store<T2>) callback) => callback<T>(this);

  @override
  String toString() =>
      debugLabel != null ? 'Store.accum<$T>($debugLabel)' : 'Store.accum<$T>';
}

// ── Internal accessors (used by scope only) ───────────────────────────────────

extension StoreInternals<T> on Store<T> {
  bool get isDerived => this is _DerivedStore<T>;
  bool get isAccum => this is _AccumStore<T>;

  DerivedStoreBody<T> get derivedBody => (this as _DerivedStore<T>).body;
  AccumStoreBody<T> get accumBody => (this as _AccumStore<T>).body;

  // Read equals via dynamic to avoid the generic-T erasure footgun: at most
  // call sites `T` is bound to `dynamic` (entries are stored in untyped maps),
  // which would fail the cast on a strongly-typed `(X, X) => bool` function.
  bool valuesEqual(Object? a, Object? b) {
    final s = this;
    final eq = (s is _DerivedStore || s is _AccumStore)
        ? (s as dynamic).equals as Function?
        : null;
    if (eq == null) return a == b;
    return (eq as dynamic)(a, b) as bool;
  }
}
