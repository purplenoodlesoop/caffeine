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
  bool stale = true;
  Set<_NodeEntry> deps = {};
  Set<_NodeEntry> dependents = {};
  StreamController<S>? controller;

  void reevaluate() {
    for (final dep in deps) {
      dep.dependents.remove(this);
    }
    deps = {};

    final source = _RecordingStateSource<S>(ownerScope, node);
    final oldValue = value;
    final newVal = node.derivedBody(source);
    value = newVal;
    stale = false;
    if (newVal != oldValue) controller?.add(newVal);
  }
}

class _AccumEntry<S> extends _NodeEntry<S> {
  _AccumEntry(super.store, super.ownerScope);

  final Map<Event, Function> handlers = {};
  final List<StreamSubscription> subscriptions = [];

  @override
  void reevaluate() => stale = false; // accum stores update via events only
}

// ── Recording StateSource ─────────────────────────────────────────────────────

class _RecordingStateSource<T> implements StateSource {
  _RecordingStateSource(this._scope, this._node);

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
  void on<E>(Event<E> event, Stream<T> Function(E) update) {
    _entry.handlers[event] = update;
    _scope._eventIndex[event] ??= [];
    _scope._eventIndex[event]!.add((_store, _entry));
  }

  @override
  void fire<V>(Event<V> event, V value) => _scope.fire(event, value);

  @override
  V read<V>(Store<V> node, {bool listen = true}) =>
      _scope._evaluateTyped(node);
}

// ── Scope interface ───────────────────────────────────────────────────────────

abstract interface class Scope implements EventSource, StateSource {
  factory Scope({StoreOverrides overrides}) = _ScopeImpl.root;

  Scope fork({StoreOverrides overrides});

  @override
  T read<T>(Store<T> node, {bool listen});

  @override
  void fire<T>(Event<T> event, T value);

  Stream<T> stream<T>(Store<T> node);

  void dispose();
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
  final Map<Event, List<(Store, _AccumEntry)>> _eventIndex = {};
  final List<_ScopeImpl> _children = [];
  bool _disposed = false;

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

  // Returns true if potentialAncestor is this scope or an ancestor of it.
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

  // Accum stores always go to root when unbound (they register event handlers
  // in their scope's _eventIndex). Derived stores are promoted to the deepest
  // dep-owner scope that is an ancestor of this scope (see _promoteIfNeeded).
  // If already evaluated, _findExistingEntry returns the promoted location.
  _ScopeImpl _ownerFor(Store store) {
    final found = _findOwner(store);
    if (found != null) return found;
    if (!store.isDerived) return _root;
    final existing = _findExistingEntry(store);
    if (existing != null) return existing;
    return this;
  }

  // After a derived store is evaluated, move its entry to the deepest dep-owner
  // scope that is an ancestor-or-equal of this scope. This ensures that all
  // descendants reading the same derived store share one instance.
  void _promoteIfNeeded(Store store, _NodeEntry entry) {
    if (entry.deps.isEmpty) return;

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
      entry.stale = false;
    } else {
      // Derived stores are initialized lazily on first read.
      _entries[store] = _NodeEntry<S>(store, this);
    }
  }

  // ── Evaluation ────────────────────────────────────────────────────────────

  T _evaluateTyped<T>(Store<T> node) {
    final effective = _resolveEffective(node);
    final owner = _ownerFor(effective);
    _ensureIn(owner, effective);
    final entry = owner._entries[effective]!;

    if (!entry.stale) return entry.value as T;

    // Only derived stores can be stale. Evaluate without emitting (no
    // controller notification here — that's only for propagation-triggered
    // recomputes in reevaluate).
    for (final dep in entry.deps) {
      dep.dependents.remove(entry);
    }
    entry.deps = {};

    final source = _RecordingStateSource<T>(owner, effective);
    final newValue = effective.derivedBody(source);
    entry.value = newValue;
    entry.stale = false;
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
      result.insert(0, entry);
    }

    for (final r in roots) {
      visit(r);
    }
    return result;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  @override
  T read<T>(Store<T> node, {bool listen = true}) => _evaluateTyped(node);

  _ScopeImpl? _findEventOwner(Event event) {
    if (_boundEvents.contains(event)) return this;
    return _parent?._findEventOwner(event);
  }

  void _localFire<T>(Event<T> event, T value) {
    final entries = _eventIndex[event];
    if (entries == null) return;
    for (final (store, entry) in entries) {
      final handler = entry.handlers[event]!;
      final stream = (handler as Stream<dynamic> Function(T))(value);
      _listenHandlerStream(store, entry, stream);
    }
  }

  void _broadcastFire<T>(Event<T> event, T value) {
    if (_disposed) return;
    _localFire(event, value);
    for (final child in _children) {
      child._broadcastFire(event, value);
    }
  }

  @override
  void fire<T>(Event<T> event, T value) {
    final owner = _findEventOwner(event);
    if (owner != null) {
      owner._broadcastFire(event, value);
    } else {
      _localFire(event, value);
    }
  }

  void _listenHandlerStream<S>(
    Store<S> store,
    _AccumEntry<S> entry,
    Stream<S> stream,
  ) {
    final owner = _findOwner(store) ?? _root;
    final sub = stream.listen((newState) {
      final old = entry.value;
      entry.value = newState;
      if (newState != old) {
        entry.controller?.add(newState);
        owner._propagate(store);
      }
    });
    entry.subscriptions.add(sub);
  }

  @override
  Stream<T> stream<T>(Store<T> node) {
    final effective = _resolveEffective(node);
    final owner = _ownerFor(effective);
    _ensureIn(owner, effective);
    final entry = owner._entries[effective]!;
    entry.controller ??= StreamController<T>.broadcast(sync: true);
    return (entry.controller as StreamController<T>).stream;
  }

  @override
  Scope fork({StoreOverrides overrides = const {}}) {
    final child = _ScopeImpl(overrides: overrides, parent: this);
    _children.add(child);
    return child;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final child in _children) {
      child.dispose();
    }
    for (final entry in _entries.values) {
      if (entry is _AccumEntry) {
        for (final sub in entry.subscriptions) {
          sub.cancel();
        }
      }
      entry.controller?.close();
    }
    _entries.clear();
    _eventIndex.clear();
  }
}

// ── MappingStoreOverride helper ───────────────────────────────────────────────

extension on MappingStoreOverride {
  void _apply(Map<Store, Store> map) => map[from] = to;
}
