import 'dart:async';

import 'event.dart';
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

  void reevaluate() {
    for (final dep in deps) {
      dep.dependents.remove(this);
    }
    deps = {};

    final source = _RecordingDerivedSource<S>(ownerScope, node);
    final oldValue = value;
    final hadOld = valueInitialized;
    final newVal = node.derivedBody(source);
    value = newVal;
    valueInitialized = true;
    stale = false;
    final changed = !hadOld || !node.valuesEqual(newVal, oldValue);
    if (changed) controller?.add(newVal);
  }
}

class _HandlerInfo {
  _HandlerInfo(this.handler, this.concurrency);
  final Function handler; // Stream<S> Function(E) erased
  final Concurrency concurrency;
  StreamSubscription? activeSub;
  final List<void Function()> queue = [];
}

class _AccumEntry<S> extends _NodeEntry<S> {
  _AccumEntry(super.store, super.ownerScope);

  // Active handler stream subscriptions (one per running handler invocation).
  final List<StreamSubscription> subscriptions = [];

  // Subscriptions opened when this store reacts to another store via
  // `ctx.on(otherStore, ...)`. Cancelled on scope dispose.
  final List<StreamSubscription> storeSourceSubs = [];

  // Per-store synthetic dispose event. Unique identity (non-const) so each
  // store's dispose handlers route only to that store.
  final Event<void> disposeEvent = Event<void>(debugLabel: 'dispose');

  @override
  void reevaluate() => stale = false; // accum stores update via handlers only
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

    if (source is Event<E>) {
      _scope._eventIndex.putIfAbsent(source, () => []).add(
            _BoundHandler(_store, _entry, info),
          );
      return;
    }

    if (source is Store<E>) {
      // React to value changes on another store: subscribe to its stream and
      // dispatch the handler with each new value. The owning scope of the
      // source store may differ from `_scope`; `stream` resolves it.
      final sub = _scope.stream(source).listen((value) {
        _scope._dispatchHandler(_store, _entry, info, value);
      });
      _entry.storeSourceSubs.add(sub);
      return;
    }

    // Source<E> is a sealed-by-convention pair (Event<E> | Store<E>); any
    // other implementation is a programming error in caffeine itself.
    throw StateError('Unsupported Source<$E> implementation: $source');
  }

  @override
  void fire<V>(Event<V> event, V value) => _scope.fire(event, value);

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
  @override
  void fire<T>(Event<T> event, T value);

  /// Subscribes to [event] dispatches reaching this scope. The handler runs
  /// synchronously when the event is fired, in addition to any store
  /// handlers registered for the same event. Cancel the subscription to
  /// stop receiving events.
  StreamSubscription<T> listen<T>(Event<T> event, void Function(T) handler);

  /// Returns a broadcast stream of [node]'s value changes. Each event flush
  /// emits at most the final value per node per batch.
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

  final Map<_AccumEntry, Object?> _pendingEmissions = {};
  final Set<(Store, _ScopeImpl)> _pendingPropagation = {};
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

    entry.evaluating = true;
    try {
      for (final dep in entry.deps) {
        dep.dependents.remove(entry);
      }
      entry.deps = {};

      final source = _RecordingDerivedSource<T>(owner, effective);
      final newValue = effective.derivedBody(source);
      entry.value = newValue;
      entry.valueInitialized = true;
      entry.stale = false;
    } finally {
      entry.evaluating = false;
    }

    if (owner == this) owner._promoteIfNeeded(effective, entry);
    return entry.value as T;
  }

  // ── Propagation ───────────────────────────────────────────────────────────

  void _propagate(Store source) {
    final sourceEntry = _entries[source];
    if (sourceEntry == null) return;

    void markStale(_NodeEntry entry) {
      if (entry.stale || entry is _AccumEntry) return;
      entry.stale = true;
      for (final dependent in entry.dependents) {
        markStale(dependent);
      }
    }

    for (final dependent in sourceEntry.dependents) {
      markStale(dependent);
    }

    for (final entry in _topoSort(sourceEntry.dependents)) {
      if (entry.node.isAccum) continue;
      entry.reevaluate();
    }
  }

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

  void _localFire<T>(Event<T> event, T value) {
    if (_disposed) return;
    final entries = _eventIndex[event];
    if (entries != null) {
      for (final bh in entries) {
        _dispatchHandler(bh.store, bh.entry, bh.info, value);
      }
    }
    final controller = _eventListenerControllers[event];
    if (controller != null && !controller.isClosed) {
      controller.add(value);
    }
  }

  void _broadcastFire<T>(Event<T> event, T value) {
    if (_disposed) return;
    _localFire(event, value);
    for (final child in List.of(_children)) {
      child._broadcastFire(event, value);
    }
  }

  @override
  void fire<T>(Event<T> event, T value) {
    _checkNotDisposed();
    final owner = _findEventOwner(event);
    (owner ?? _root)._broadcastFire(event, value);
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

  void _dispatchHandler<S, E>(
    Store<S> store,
    _AccumEntry<S> entry,
    _HandlerInfo info,
    E value,
  ) {
    final handler = info.handler as Stream<S> Function(E);
    switch (info.concurrency) {
      case Concurrency.parallel:
        _subscribeHandler(store, entry, info, handler(value));
      case Concurrency.drop:
        if (info.activeSub != null) return;
        _subscribeHandler(store, entry, info, handler(value));
      case Concurrency.restart:
        info.activeSub?.cancel();
        info.activeSub = null;
        _subscribeHandler(store, entry, info, handler(value));
      case Concurrency.queue:
        if (info.activeSub != null) {
          info.queue.add(
            () => _subscribeHandler(store, entry, info, handler(value)),
          );
        } else {
          _subscribeHandler(store, entry, info, handler(value));
        }
    }
  }

  void _subscribeHandler<S>(
    Store<S> store,
    _AccumEntry<S> entry,
    _HandlerInfo info,
    Stream<S> stream,
  ) {
    final owner = _findOwner(store) ?? _root;
    late StreamSubscription<S> sub;
    sub = stream.listen(
      (newState) {
        final old = entry.value;
        entry.value = newState;
        final changed = !store.valuesEqual(newState, old);
        if (changed) {
          final root = owner._root;
          if (entry.controller != null) {
            root._pendingEmissions[entry] = newState;
          }
          root._pendingPropagation.add((store, owner));
          if (!root._flushScheduled) {
            root._flushScheduled = true;
            scheduleMicrotask(root._flushBatch);
          }
        }
      },
      onError: Zone.current.handleUncaughtError,
      onDone: () {
        entry.subscriptions.remove(sub);
        if (identical(info.activeSub, sub)) info.activeSub = null;
        if (info.queue.isNotEmpty) {
          final next = info.queue.removeAt(0);
          next();
        }
      },
    );
    if (info.concurrency != Concurrency.parallel) info.activeSub = sub;
    entry.subscriptions.add(sub);
  }

  void _flushBatch() {
    _flushScheduled = false;

    for (final MapEntry(:key, :value) in _pendingEmissions.entries) {
      final controller = key.controller;
      if (controller != null && !controller.isClosed) {
        controller.add(value);
      }
    }
    _pendingEmissions.clear();

    final pending = Set.of(_pendingPropagation);
    _pendingPropagation.clear();
    for (final (store, scope) in pending) {
      if (!scope._disposed) scope._propagate(store);
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
    entry.controller ??= StreamController<T>.broadcast(sync: true);
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
        _localFire(entry.disposeEvent, null);
      }
    }
    _disposed = true;
    for (final entry in _entries.values) {
      if (entry is _AccumEntry) {
        for (final sub in entry.storeSourceSubs) {
          sub.cancel();
        }
        for (final sub in entry.subscriptions) {
          sub.cancel();
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
    _pendingEmissions.clear();
    _pendingPropagation.clear();
    _children.clear();
  }
}

// ── MappingStoreOverride helper ───────────────────────────────────────────────

extension on MappingStoreOverride {
  void _apply(Map<Store, Store> map) => map[from] = to;
}
