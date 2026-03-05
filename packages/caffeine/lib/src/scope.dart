import 'dart:async';

import 'event.dart';
import 'stateful.dart';
import 'store.dart';
import 'store_override.dart';
import 'store_reference.dart';

// ── Node entries — all mutable runtime state ──────────────────────────────────

class _NodeEntry<S> {
  _NodeEntry(this.node);

  final Stateful<S> node;
  S? value;
  bool stale = true;
  Set<Stateful> deps = {};
  Set<Stateful> dependents = {};
  StreamController<S>? controller;

  /// Clears deps, re-evaluates [node.body], updates [value], and emits if changed.
  void reevaluate(_ScopeImpl scope) {
    for (final dep in deps) {
      scope._rawEntry(dep)?.dependents.remove(node);
    }
    deps = {};

    final snapshot = _RecordingSnapshot<S>(scope, node);
    final oldValue = value;
    final newVal = node.body(snapshot);
    value = newVal;
    stale = false;
    if (newVal != oldValue) controller?.add(newVal);
  }
}

class _StoreEntry<S> extends _NodeEntry<S> {
  _StoreEntry(super.store);

  late void Function(Object?) handleEvent;
  StreamSubscription<Object?>? externalSub;

  @override
  void reevaluate(_ScopeImpl scope) {
    // Store values are updated via events only, not body recomputation.
    stale = false;
  }
}

// ── Recording snapshot ────────────────────────────────────────────────────────

class _RecordingSnapshot<T> implements Snapshot<T> {
  _RecordingSnapshot(this._scope, this._node);

  final _ScopeImpl _scope;
  final Stateful<T> _node;

  @override
  T? get current => _scope._rawEntry(_node)?.value as T?;

  @override
  A call<A>(Stateful<A> dep) {
    // Evaluate dep first (ensures its entry exists with the correct type).
    final result = _scope._evaluateTyped(dep);

    // Register _node as a dependent of dep, and dep as a dependency of _node.
    if (dep is Store) {
      _scope._storeEntry(dep as Store)?.dependents.add(_node);
    } else {
      _scope._getOrCreate(dep).dependents.add(_node);
    }
    _scope._getOrCreate(_node).deps.add(dep);

    return result;
  }
}

// ── Scope interface ───────────────────────────────────────────────────────────

abstract interface class Scope {
  factory Scope({Set<StoreOverride> references = const {}}) =>
      _ScopeImpl.root(references: references);

  Scope fork({Set<StoreReference> references = const {}});

  T read<T>(Stateful<T> state);
  void fire<E>(Event<E> event);
  Stream<T> stream<T>(Stateful<T> state);
  void dispose();
}

// ── _ScopeImpl ────────────────────────────────────────────────────────────────

class _ScopeImpl implements Scope {
  _ScopeImpl({Set<StoreReference> references = const {}, _ScopeImpl? parent})
      : _parent = parent {
    for (final ref in references) {
      if (ref is StoreOverride) {
        _overrides[ref.from] = ref.to;
      } else if (ref is Store) {
        _bound.add(ref);
      }
    }
  }

  _ScopeImpl.root({Set<StoreOverride> references = const {}}) : _parent = null {
    for (final ref in references) {
      _overrides[ref.from] = ref.to;
    }
  }

  final _ScopeImpl? _parent;
  final Map<Store, Store> _overrides = {};
  final Set<Store> _bound = {};
  final Map<Stateful, _NodeEntry> _entries = {};
  final List<_ScopeImpl> _children = [];
  bool _disposed = false;

  // ── Entry helpers ─────────────────────────────────────────────────────────

  _NodeEntry? _rawEntry(Stateful node) => _entries[node];

  _NodeEntry<S> _getOrCreate<S>(Stateful<S> node) {
    final existing = _entries[node];
    if (existing != null) return existing as _NodeEntry<S>;
    return _createEntry(node);
  }

  _NodeEntry<S> _createEntry<S>(Stateful<S> node) {
    final entry = _NodeEntry<S>(node);
    _entries[node] = entry;
    return entry;
  }

  // ── Store resolution ──────────────────────────────────────────────────────

  Store _resolveEffective(Store store) {
    Store? override = _overrides[store];
    if (override == null) {
      _ScopeImpl? ancestor = _parent;
      while (ancestor != null && override == null) {
        override = ancestor._overrides[store];
        ancestor = ancestor._parent;
      }
    }
    return override ?? store;
  }

  _ScopeImpl? _findOwner(Store store) {
    if (_bound.contains(store)) return this;
    return _parent?._findOwner(store);
  }

  _ScopeImpl get _root {
    _ScopeImpl s = this;
    while (s._parent != null) {
      s = s._parent;
    }
    return s;
  }

  /// Returns the entry for [store] from its owning scope, or null if not yet initialized.
  _StoreEntry? _storeEntry(Store store) {
    final effective = _resolveEffective(store);
    final owner = _findOwner(effective) ?? _root;
    return owner._entries[effective] as _StoreEntry?;
  }

  void _ensureInitialized(Store store) {
    final effective = _resolveEffective(store);
    final owner = _findOwner(effective) ?? _root;
    if (!owner._entries.containsKey(effective)) {
      effective.callTyped(<S, E>(Store<S, E> typed) => owner._initStore(typed));
    }
  }

  void _initStore<S, E>(Store<S, E> store) {
    final entry = _StoreEntry<S>(store);
    _entries[store] = entry;

    final (initial, update) = store.describe();
    final (initialState, effectsFactory) = initial();
    entry.value = initialState;
    entry.stale = false;

    final owner = this;
    entry.handleEvent = (Object? event) {
      final e = event as E;
      final oldState = entry.value as S;
      final (newState, effects) = update(e, oldState);
      if (newState != oldState) {
        entry.value = newState;
        entry.controller?.add(newState);
        owner._propagate(store);
      }
      _runEffects(effects);
    };

    _runEffects(effectsFactory);

    if (store.subscribeFactory != null) {
      entry.externalSub = store
          .subscribeFactory!(initialState)
          .listen((e) => entry.handleEvent(e));
    }
  }

  // ── Evaluation ────────────────────────────────────────────────────────────

  T _evaluateTyped<T>(Stateful<T> node) {
    if (node is Store) {
      final effective = _resolveEffective(node as Store);
      _ensureInitialized(effective);
      final owner = _findOwner(effective) ?? _root;
      return owner._entries[effective]!.value as T;
    }

    final entry = _getOrCreate(node);
    if (!entry.stale) return entry.value as T;

    for (final dep in entry.deps) {
      _rawEntry(dep)?.dependents.remove(node);
    }
    entry.deps = {};

    final snapshot = _RecordingSnapshot<T>(this, node);
    final newValue = node.body(snapshot);
    entry.value = newValue;
    entry.stale = false;
    return newValue;
  }

  // ── Propagation ───────────────────────────────────────────────────────────

  void _propagate(Stateful source) {
    final sourceEntry = _entries[source];
    if (sourceEntry == null) return;

    void markStale(Stateful node) {
      final e = _entries[node];
      if (e == null || e.stale || node is Store) return;
      e.stale = true;
      for (final dep in e.dependents) {
        markStale(dep);
      }
    }

    for (final dep in sourceEntry.dependents) {
      markStale(dep);
    }

    for (final node in _topoSort(sourceEntry.dependents)) {
      if (node is Store) continue;
      _entries[node]?.reevaluate(this);
    }
  }

  List<Stateful> _topoSort(Set<Stateful> roots) {
    final result = <Stateful>[];
    final visited = <Stateful>{};

    void visit(Stateful node) {
      if (visited.contains(node) || node is Store) return;
      visited.add(node);
      final e = _entries[node];
      if (e != null) {
        for (final dep in e.dependents) {
          visit(dep);
        }
      }
      result.insert(0, node);
    }

    for (final r in roots) {
      visit(r);
    }
    return result;
  }

  void _runEffects(Stream<Event> Function() factory) {
    factory().listen(fire);
  }

  // ── Public API ────────────────────────────────────────────────────────────

  @override
  T read<T>(Stateful<T> state) => _evaluateTyped(state);

  @override
  void fire<E>(Event<E> event) {
    final consumer = event.consumer;
    if (consumer is! Store) return;
    final effective = _resolveEffective(consumer as Store);
    _ensureInitialized(effective);
    final owner = _findOwner(effective) ?? _root;
    (owner._entries[effective] as _StoreEntry).handleEvent(event.event);
  }

  @override
  Stream<T> stream<T>(Stateful<T> state) {
    if (state is Store) {
      final effective = _resolveEffective(state as Store);
      _ensureInitialized(effective);
      final owner = _findOwner(effective) ?? _root;
      final entry = owner._entries[effective]! as _StoreEntry<T>;
      entry.controller ??= StreamController<T>.broadcast(sync: true);
      return entry.controller!.stream;
    }

    final entry = _getOrCreate(state);
    _evaluateTyped(state);
    entry.controller ??= StreamController<T>.broadcast(sync: true);
    return entry.controller!.stream;
  }

  @override
  Scope fork({Set<StoreReference> references = const {}}) {
    final child = _ScopeImpl(references: references, parent: this);
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
      if (entry is _StoreEntry) entry.externalSub?.cancel();
      entry.controller?.close();
    }
    _entries.clear();
  }
}
