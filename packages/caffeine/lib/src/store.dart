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

/// Read API outside `Store.derive` bodies. Implemented by `Scope` and by the
/// accum [StoreAcc] context. Reads here are one-shot — there is no `listen:`
/// parameter, so passing one is a compile error.
abstract interface class StateSource {
  T read<T>(Store<T> node);
}

/// Read API inside `Store.derive` bodies. Extends [StateSource] with a
/// `listen:` parameter — every read tracked here becomes a dependency of the
/// derived store, and `listen: false` opts out for that read only. The body
/// is automatically recomputed whenever a recorded dependency changes.
abstract interface class DerivedSource implements StateSource {
  @override
  T read<T>(Store<T> node, {bool listen = true});
}

/// Sugar: `someStore(source)` is short for `source.read(someStore)`. Works on
/// any [StateSource] — a `Scope`, a [StoreAcc] context, or a [DerivedSource]
/// recording context. Inside a derive body the read is tracked as a
/// dependency by default; to opt out, call `source.read(store, listen: false)`
/// explicitly (the shorthand has no `listen:` parameter, so the type system
/// prevents the impossible call outside derive bodies).
extension StoreReadX<T> on Store<T> {
  T call(StateSource source) => source.read(this);
}

/// Concurrency strategy for a handler registered via [StoreState.on].
///
/// Each strategy controls what happens when the source fires (or a source
/// store changes) while a previous invocation of its handler is still
/// emitting states:
///
/// - [parallel] (default): every invocation runs concurrently; their `yield`s
///   interleave in arrival order. Preserves caffeine ≤ 2 semantics.
/// - [drop]: while an invocation is in flight, additional fires are dropped.
///   Useful for "throttle until first completes".
/// - [restart]: the prior invocation is cancelled and replaced. Useful for
///   debounced async work like search queries.
/// - [queue]: invocations are serialized; each waits for the previous to
///   complete before starting. Useful for ordered side effects.
enum Concurrency { parallel, drop, restart, queue }

/// Context exposed to a [Store.accum] body. Lets the body register handlers
/// for any [Source] (an [Event] or another [Store]) and observe its own
/// dispose lifecycle via [dispose].
abstract interface class StoreState<S> {
  /// The current value of this store.
  S get current;

  /// Registers a handler that runs whenever [source] emits — either an
  /// [Event] is fired or a source [Store]'s value changes. The handler
  /// returns a [Stream] of new states; each emitted state replaces [current]
  /// and triggers downstream propagation.
  ///
  /// Multiple handlers can be registered for the same source; all run on
  /// every emission.
  ///
  /// See [Concurrency] for behavior when the source emits while a prior
  /// invocation is still running.
  void on<E>(
    Source<E> source,
    Stream<S> Function(E) update, {
    Concurrency concurrency = Concurrency.parallel,
  });

  /// A per-store event that fires once when the scope owning this store is
  /// disposed. Subscribe via [on] to clean up external resources:
  ///
  /// ```dart
  /// final timer = Timer.periodic(...);
  /// ctx.on(ctx.dispose, (_) async* { timer.cancel(); });
  /// ```
  ///
  /// Same primitive as any other event — no special callback API.
  Event<void> get dispose;
}

/// Accum store context: combines [StoreState] (handler registration + the
/// dispose event), [EventSource] (firing follow-on events), and [StateSource]
/// (reading other stores).
abstract interface class StoreAcc<T>
    implements StoreState<T>, EventSource, StateSource {}

typedef DerivedStoreBody<T> = T Function(DerivedSource source);
typedef AccumStoreBody<T> = T Function(StoreAcc<T> source);

/// A reactive value of type [T].
///
/// Two flavors:
///
/// - [Store.derive] — lazy derived value. Its body is a pure function over a
///   [DerivedSource]; every read inside the body registers a dependency, and
///   the value is recomputed automatically when a dependency changes.
///   Recomputation is glitch-free: diamond-shaped dependency graphs evaluate
///   each downstream node at most once per propagation cycle.
///
/// - [Store.accum] — event-driven stateful store. Its body runs once at scope
///   init and registers handlers via `ctx.on(source, handler)`. State
///   transitions only happen in response to emissions.
///
/// Stores have identity — two `Store` instances are equal only by reference.
/// Don't construct a store inside a build/render function unless you mean to
/// create a new identity each time.
///
/// Stores are also [Source]s: another accum store can react to value changes
/// via `ctx.on(otherStore, handler)`. They are not [Event]s, though — there
/// is no extension that lets you call a store like `store(source, value)` to
/// mutate it. The only way to change a store's value is from inside its own
/// handlers.
abstract interface class Store<T> implements Source<T>, StoreOverride {
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
  /// [StoreAcc] context to register `on(source, handler)` clauses, fire
  /// follow-on events, and (optionally) subscribe to `ctx.dispose`.
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
