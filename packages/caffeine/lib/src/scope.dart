import 'dart:async';

import 'override.dart';
import 'store.dart';

// ── Node entries ──────────────────────────────────────────────────────────────

class _NodeEntry<S> {
  _NodeEntry(this.node, this.ownerScope);

  final Store<S> node;
  _ScopeImpl ownerScope;
  S? value;
  bool valueInitialized = false;
  bool stale = true;
  bool evaluating = false;
  Set<_NodeEntry> deps = {};
  Set<_NodeEntry> dependents = {};
  StreamController<S>? controller;

  // Last value delivered on [controller]. A flush emits only when the settled
  // value differs from it, so a change that reverts within a batch is silent.
  Object? notified;

  // Recomputes a derived value from its body, re-recording dependencies.
  void recompute() {
    evaluating = true;
    try {
      for (final dep in deps) {
        dep.dependents.remove(this);
      }
      deps = {};
      value = node.derivedBody(_RecordingDerivedSource<S>(ownerScope, node));
      valueInitialized = true;
      stale = false;
    } finally {
      evaluating = false;
    }
  }

  // Marks every transitive derived dependent stale. Called the moment a source
  // changes, so a read before the next flush recomputes instead of returning a
  // value computed from the old source. A stale node's dependents are already
  // stale, so the walk stops there.
  void invalidateDependents() {
    for (final dependent in dependents) {
      if (dependent.stale) continue;
      dependent.stale = true;
      dependent.invalidateDependents();
    }
  }

  void notify() {
    final c = controller;
    if (c == null || c.isClosed || node.valuesEqual(value, notified)) return;
    notified = value;
    c.add(value as S);
  }
}

// One running handler invocation. [done] completes when its stream finishes or
// it is cancelled (by `restart` or scope dispose), so `fire` can await it.
class _Invocation {
  _Invocation(this.done);
  final Completer<void> done;
  late final StreamSubscription sub;

  void complete() {
    if (!done.isCompleted) done.complete();
  }

  void cancel() {
    sub.cancel();
    complete();
  }
}

class _HandlerInfo {
  _HandlerInfo(this.handler, this.concurrency);
  final Function handler; // Stream<S> Function(E) erased
  final Concurrency concurrency;
  _Invocation? active;
  final List<({Completer<void> done, void Function() start})> queue = [];
}

class _AccumEntry<S> extends _NodeEntry<S> {
  _AccumEntry(super.store, super.ownerScope);

  // Running handler invocations.
  final List<_Invocation> invocations = [];

  // Every handler registered by this store's body; dispose completes their
  // queued invocations.
  final List<_HandlerInfo> handlers = [];

  // Subscriptions opened when this store reacts to another store via
  // `ctx.on(otherStore, ...)`. Cancelled on scope dispose.
  final List<StreamSubscription> storeSourceSubs = [];

  // Per-store synthetic dispose event. One instance per entry so each
  // store's dispose handlers route only to that store.
  final Event<void> disposeEvent = Event<void>(debugLabel: 'dispose');
}

// ── Recording DerivedSource ───────────────────────────────────────────────────

class _RecordingDerivedSource<T> implements DerivedSource {
  _RecordingDerivedSource(this._scope, this._node);

  final _ScopeImpl _scope;
  final Store<T> _node;

  @override
  A read<A>(Store<A> dep, {bool listen = true}) {
    final result = _scope._evaluateTyped(dep);

    if (listen) {
      // dep may live in a different scope; use its actual entry so propagation
      // reaches this derived node regardless of scope boundaries.
      final depOwner = _scope._ownerFor(dep);
      final depEntry = depOwner._entries[dep]!;
      final nodeEntry = _scope._entries[_node]!;
      depEntry.dependents.add(nodeEntry);
      nodeEntry.deps.add(depEntry);
    }

    return result;
  }
}

// ── StoreAcc implementation ───────────────────────────────────────────────────

class _StoreAccImpl<T> implements StoreAcc<T> {
  _StoreAccImpl(this._scope, this._entry, this._store);

  final _ScopeImpl _scope;
  final _AccumEntry<T> _entry;
  final Store<T> _store;

  @override
  T get current => _entry.value as T;

  @override
  Event<void> get dispose => _entry.disposeEvent;

  @override
  void on<E>(
    Source<E> source,
    Stream<T> Function(E) update, {
    Concurrency concurrency = Concurrency.parallel,
  }) {
    final info = _HandlerInfo(update, concurrency);
    _entry.handlers.add(info);

    switch (source) {
      case Event<E>():
        _scope._eventIndex.putIfAbsent(source, () => []).add(
              _BoundHandler(_store, _entry, info),
            );
      case Store<E>():
        // React to value changes on another store: subscribe to its stream and
        // dispatch the handler with each new value. The owning scope of the
        // source store may differ from `_scope`; `stream` resolves it.
        final sub = _scope.stream(source).listen((value) {
          _scope._dispatchHandler(_store, _entry, info, value);
        });
        _entry.storeSourceSubs.add(sub);
    }
  }

  @override
  Future<void> fire<V>(Event<V> event, V value) => _scope.fire(event, value);

  @override
  V read<V>(Store<V> node) => _scope._evaluateTyped(node);
}

// Tracks one handler registration in the per-scope event index.
class _BoundHandler {
  _BoundHandler(this.store, this.entry, this.info);
  final Store store;
  final _AccumEntry entry;
  final _HandlerInfo info;
}

// ── Scope interface ───────────────────────────────────────────────────────────

/// Runtime that owns the reactive graph, dispatches events, and manages
/// store lifetimes.
///
/// Scopes form a tree. Child scopes are created via [Scope.fork]; a store
/// bound to a child scope is destroyed when that child is disposed. Stores
/// that aren't explicitly bound to any scope live at the root.
abstract interface class Scope implements EventSource, StateSource {
  /// Creates a root scope. Stores or events in [overrides] are bound to this
  /// scope; substitutions (via [MappingStoreOverride]) are applied to all
  /// descendants.
  factory Scope({StoreOverrides overrides}) = _ScopeImpl.root;

  /// Creates a child scope. Stores or events in [overrides] are bound to the
  /// child; mappings apply to descendants of the child only.
  Scope fork({StoreOverrides overrides});

  /// Reads the current value of [node]. Triggers initialization if needed.
  /// Reads outside `Store.derive` are always one-shot.
  @override
  T read<T>(Store<T> node);

  /// Dispatches [event] with [value]. Routes to the scope that owns [event]
  /// (or root, if unbound) and broadcasts the event through that subtree.
  ///
  /// Handlers start synchronously but apply their `yield`s asynchronously, so
  /// state has not changed yet when this returns. The returned future
  /// completes once every handler invocation this call started has finished
  /// (or was dropped or cancelled) and its states have propagated to derived
  /// stores and streams. Await it to read the settled state:
  ///
  /// ```dart
  /// await increment(scope);
  /// scope.read(counter); // updated
  /// ```
  ///
  /// Follow-up events fired by a handler are included only if that handler
  /// awaits them. Handler errors are reported to the zone, not the future.
  @override
  Future<void> fire<T>(Event<T> event, T value);

  /// Subscribes to [event] dispatches reaching this scope. The handler runs
  /// synchronously when the event is fired, in addition to any store
  /// handlers registered for the same event. Cancel the subscription to
  /// stop receiving events.
  StreamSubscription<T> listen<T>(Event<T> event, void Function(T) handler);

  /// Returns a broadcast stream of [node]'s value changes. Each flush emits
  /// at most the final value per node, and only if it differs from the last
  /// value emitted.
  Stream<T> stream<T>(Store<T> node);

  /// Disposes this scope and all descendants. Fires each accum store's
  /// `ctx.dispose` event, cancels subscriptions, and closes value streams.
  void dispose();

  /// True once [dispose] has been called.
  bool get isDisposed;

  /// Stores explicitly bound to this scope (via overrides). Diagnostic only.
  Iterable<Store> get debugBoundStores;

  /// Events explicitly bound to this scope (via overrides). Diagnostic only.
  Iterable<Event> get debugBoundEvents;

  /// Child scopes forked from this scope. Diagnostic only.
  Iterable<Scope> get debugChildren;
}

// ── _ScopeImpl ────────────────────────────────────────────────────────────────

class _ScopeImpl implements Scope {
  _ScopeImpl({StoreOverrides overrides = const {}, _ScopeImpl? parent})
      : _parent = parent {
    for (final ref in overrides) {
      if (ref is MappingStoreOverride) {
        ref._apply(_overrides);
        _bound.add(ref.to); // target store is owned by this scope
      } else if (ref is Store) {
        _bound.add(ref);
      } else if (ref is Event) {
        _boundEvents.add(ref);
      }
    }
  }

  _ScopeImpl.root({StoreOverrides overrides = const {}}) : _parent = null {
    for (final ref in overrides) {
      if (ref is MappingStoreOverride) {
        ref._apply(_overrides);
      } else if (ref is Event) {
        _boundEvents.add(ref);
      }
    }
  }

  final _ScopeImpl? _parent;
  final Map<Store, Store> _overrides = {};
  final Set<Store> _bound = {};
  final Set<Event> _boundEvents = {};
  final Map<Store, _NodeEntry> _entries = {};
  final Map<Event, List<_BoundHandler>> _eventIndex = {};
  final Map<Event, StreamController> _eventListenerControllers = {};
  final List<_ScopeImpl> _children = [];
  bool _disposed = false;

  @override
  bool get isDisposed => _disposed;

  @override
  Iterable<Store> get debugBoundStores => List.unmodifiable(_bound);

  @override
  Iterable<Event> get debugBoundEvents => List.unmodifiable(_boundEvents);

  @override
  Iterable<Scope> get debugChildren => List.unmodifiable(_children);

  void _checkNotDisposed() {
    if (_disposed) throw StateError('Scope is disposed');
  }

  // ── Batch flush (meaningful at root; children forward to _root) ───────────

  // Accum entries whose value changed since the last flush.
  final Set<_AccumEntry> _pending = {};
  bool _flushScheduled = false;

  // ── Store resolution ──────────────────────────────────────────────────────

  Store<T> _resolveEffective<T>(Store<T> store) {
    Store? override = _overrides[store];
    if (override == null) {
      _ScopeImpl? ancestor = _parent;
      while (ancestor != null && override == null) {
        override = ancestor._overrides[store];
        ancestor = ancestor._parent;
      }
    }
    return (override ?? store) as Store<T>;
  }

  _ScopeImpl? _findOwner(Store store) {
    if (_bound.contains(store)) return this;
    return _parent?._findOwner(store);
  }

  // Walks ancestors to find a derived store that was already evaluated and
  // possibly promoted to an ancestor scope.
  _ScopeImpl? _findExistingEntry(Store store) {
    if (_entries.containsKey(store)) return this;
    return _parent?._findExistingEntry(store);
  }

  bool _isAncestorOrEqual(_ScopeImpl potentialAncestor) {
    _ScopeImpl? cursor = this;
    while (cursor != null) {
      if (cursor == potentialAncestor) return true;
      cursor = cursor._parent;
    }
    return false;
  }

  _ScopeImpl get _root {
    _ScopeImpl s = this;
    while (s._parent != null) {
      s = s._parent;
    }
    return s;
  }

  // Accum stores always go to root when unbound. Derived stores are promoted
  // to the deepest dep-owner scope that is an ancestor of this scope.
  _ScopeImpl _ownerFor(Store store) {
    final found = _findOwner(store);
    if (found != null) return found;
    if (!store.isDerived) return _root;
    final existing = _findExistingEntry(store);
    if (existing != null) return existing;
    return this;
  }

  void _promoteIfNeeded(Store store, _NodeEntry entry) {
    if (entry.deps.isEmpty) {
      if (this != _root) {
        _entries.remove(store);
        _root._entries[store] = entry;
        entry.ownerScope = _root;
      }
      return;
    }

    _ScopeImpl? best;
    int bestDepth = -1;

    for (final dep in entry.deps) {
      final candidate = dep.ownerScope;
      if (!_isAncestorOrEqual(candidate)) continue;
      int depth = 0;
      _ScopeImpl? c = candidate;
      while (c != null) {
        depth++;
        c = c._parent;
      }
      if (depth > bestDepth) {
        bestDepth = depth;
        best = candidate;
      }
    }

    if (best == null || best == this) return;

    _entries.remove(store);
    best._entries[store] = entry;
    entry.ownerScope = best;
  }

  void _ensureIn(_ScopeImpl owner, Store effective) {
    if (!owner._entries.containsKey(effective)) {
      effective.callTyped(<S>(Store<S> typed) => owner._initStore(typed));
    }
  }

  void _initStore<S>(Store<S> store) {
    if (store.isAccum) {
      final entry = _AccumEntry<S>(store, this);
      _entries[store] = entry;

      final ctx = _StoreAccImpl<S>(this, entry, store);
      final initialValue = store.accumBody(ctx);
      entry.value = initialValue;
      entry.valueInitialized = true;
      entry.stale = false;
    } else {
      _entries[store] = _NodeEntry<S>(store, this);
    }
  }

  // ── Evaluation ────────────────────────────────────────────────────────────

  T _evaluateTyped<T>(Store<T> node) {
    final effective = _resolveEffective(node);
    final owner = _ownerFor(effective);
    _ensureIn(owner, effective);
    final entry = owner._entries[effective]!;

    if (entry.evaluating) {
      throw StateError(
        'Cycle detected: $effective depends on itself (directly or transitively).',
      );
    }

    if (!entry.stale) return entry.value as T;

    entry.recompute();

    if (owner == this) owner._promoteIfNeeded(effective, entry);
    return entry.value as T;
  }

  // ── Propagation ───────────────────────────────────────────────────────────

  List<_NodeEntry> _topoSort(Set<_NodeEntry> roots) {
    final result = <_NodeEntry>[];
    final visited = <Store>{};

    void visit(_NodeEntry entry) {
      if (visited.contains(entry.node) || entry.node.isAccum) return;
      visited.add(entry.node);
      for (final dependent in entry.dependents) {
        visit(dependent);
      }
      result.add(entry);
    }

    for (final r in roots) {
      visit(r);
    }
    return result.reversed.toList();
  }

  // ── Public API ────────────────────────────────────────────────────────────

  @override
  T read<T>(Store<T> node) {
    _checkNotDisposed();
    return _evaluateTyped(node);
  }

  _ScopeImpl? _findEventOwner(Event event) {
    if (_boundEvents.contains(event)) return this;
    return _parent?._findEventOwner(event);
  }

  void _localFire<T>(Event<T> event, T value, List<Future<void>> started) {
    if (_disposed) return;
    final entries = _eventIndex[event];
    if (entries != null) {
      for (final bh in entries) {
        started.add(_dispatchHandler(bh.store, bh.entry, bh.info, value));
      }
    }
    final controller = _eventListenerControllers[event];
    if (controller != null && !controller.isClosed) {
      controller.add(value);
    }
  }

  void _broadcastFire<T>(Event<T> event, T value, List<Future<void>> started) {
    if (_disposed) return;
    _localFire(event, value, started);
    for (final child in List.of(_children)) {
      child._broadcastFire(event, value, started);
    }
  }

  @override
  Future<void> fire<T>(Event<T> event, T value) async {
    _checkNotDisposed();
    final started = <Future<void>>[];
    (_findEventOwner(event) ?? _root)._broadcastFire(event, value, started);
    await Future.wait(started);
    // The last yields may still sit in the pending batch; settle them so the
    // caller sees propagated state and stream listeners have been notified.
    _root._flushBatch();
  }

  @override
  StreamSubscription<T> listen<T>(Event<T> event, void Function(T) handler) {
    _checkNotDisposed();
    final controller = _eventListenerControllers.putIfAbsent(
      event,
      () => StreamController<T>.broadcast(sync: true),
    );
    return (controller.stream as Stream<T>).listen(handler);
  }

  // Starts (or drops, or queues) one handler invocation according to its
  // concurrency strategy. The future completes when that invocation finishes.
  Future<void> _dispatchHandler<S, E>(
    Store<S> store,
    _AccumEntry<S> entry,
    _HandlerInfo info,
    E value,
  ) {
    final handler = info.handler as Stream<S> Function(E);
    Future<void> start([Completer<void>? done]) =>
        _subscribeHandler(entry, info, handler(value), done ?? Completer());

    switch (info.concurrency) {
      case Concurrency.parallel:
        return start();
      case Concurrency.drop:
        if (info.active != null) return Future.value();
        return start();
      case Concurrency.restart:
        info.active?.cancel();
        info.active = null;
        return start();
      case Concurrency.queue:
        if (info.active == null) return start();
        final done = Completer<void>();
        info.queue.add((done: done, start: () => start(done)));
        return done.future;
    }
  }

  Future<void> _subscribeHandler<S>(
    _AccumEntry<S> entry,
    _HandlerInfo info,
    Stream<S> stream,
    Completer<void> done,
  ) {
    final invocation = _Invocation(done);
    invocation.sub = stream.listen(
      (newState) {
        if (entry.node.valuesEqual(newState, entry.value)) return;
        entry.value = newState;
        // Invalidate now rather than at flush: a read in between recomputes
        // derived stores instead of pairing the new value with stale ones.
        entry.invalidateDependents();
        final root = entry.ownerScope._root;
        root._pending.add(entry);
        if (!root._flushScheduled) {
          root._flushScheduled = true;
          scheduleMicrotask(root._flushBatch);
        }
      },
      onError: Zone.current.handleUncaughtError,
      onDone: () {
        entry.invocations.remove(invocation);
        if (identical(info.active, invocation)) info.active = null;
        invocation.complete();
        if (info.queue.isNotEmpty) info.queue.removeAt(0).start();
      },
    );
    if (info.concurrency != Concurrency.parallel) info.active = invocation;
    entry.invocations.add(invocation);
    return done.future;
  }

  // Notifies streams of every changed accum store and of the derived stores
  // downstream of them. Dependents were invalidated when the change happened;
  // only observed ones (with a stream) are recomputed here, in topological
  // order, so each recomputes at most once. Unobserved ones stay lazy.
  void _flushBatch() {
    _flushScheduled = false;
    final sources = List.of(_pending);
    _pending.clear();
    for (final source in sources) {
      if (source.ownerScope._disposed) continue;
      source.notify();
      for (final entry in _topoSort(source.dependents)) {
        if (entry.controller == null || entry.ownerScope._disposed) continue;
        if (entry.stale) entry.recompute();
        entry.notify();
      }
    }
  }

  @override
  Stream<T> stream<T>(Store<T> node) {
    _checkNotDisposed();
    // Force evaluation so derived stores set up their dependency edges —
    // without this, subscribers receive no events because nothing propagates
    // until the store is first read.
    _evaluateTyped(node);
    final effective = _resolveEffective(node);
    final owner = _ownerFor(effective);
    final entry = owner._entries[effective]!;
    if (entry.controller == null) {
      entry.controller = StreamController<T>.broadcast(sync: true);
      entry.notified = entry.value;
    }
    return (entry.controller as StreamController<T>).stream;
  }

  @override
  Scope fork({StoreOverrides overrides = const {}}) {
    _checkNotDisposed();
    final child = _ScopeImpl(overrides: overrides, parent: this);
    _children.add(child);
    return child;
  }

  @override
  void dispose() => _disposeImpl(unregister: true);

  void _disposeImpl({required bool unregister}) {
    if (_disposed) return;
    if (unregister) _parent?._children.remove(this);
    for (final child in List.of(_children)) {
      child._disposeImpl(unregister: false);
    }
    // Fire each accum store's dispose event BEFORE clearing the index, so
    // handlers registered via `ctx.on(ctx.dispose, ...)` are dispatched. The
    // handler streams are async, so cleanup side effects (e.g. timer.cancel())
    // run as microtasks after this scope's teardown completes. That is fine:
    // they target external resources, not scope state.
    for (final entry in _entries.values) {
      if (entry is _AccumEntry) {
        _localFire(entry.disposeEvent, null, []);
      }
    }
    _disposed = true;
    for (final entry in _entries.values) {
      if (entry is _AccumEntry) {
        for (final sub in entry.storeSourceSubs) {
          sub.cancel();
        }
        for (final invocation in entry.invocations) {
          invocation.cancel();
        }
        for (final info in entry.handlers) {
          for (final queued in info.queue) {
            queued.done.complete();
          }
          info.queue.clear();
        }
      }
      entry.controller?.close();
    }
    for (final controller in _eventListenerControllers.values) {
      controller.close();
    }
    _entries.clear();
    _eventIndex.clear();
    _eventListenerControllers.clear();
    _bound.clear();
    _overrides.clear();
    _boundEvents.clear();
    _pending.clear();
    _children.clear();
  }
}

// ── MappingStoreOverride helper ───────────────────────────────────────────────

extension on MappingStoreOverride {
  void _apply(Map<Store, Store> map) => map[from] = to;
}
