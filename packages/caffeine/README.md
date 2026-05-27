# caffeine

A reactive microstore library for Dart with managed side effects. Caffeine gives you predictable, composable state machines where every state transition is driven by a typed event, every side effect is an explicit async stream, and reactivity propagates automatically through derived values — with no hidden mutations and no boilerplate.

---

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
  - [Event](#event)
  - [Store.accum — Stateful Stores](#storeaccum--stateful-stores)
  - [Store.derive — Derived State](#storederive--derived-state)
  - [Scope — The Runtime](#scope--the-runtime)
  - [StoreOverrides](#storeoverrides)
- [Managed Effects](#managed-effects)
  - [Handling Events](#handling-events)
  - [Cross-Store Dispatch](#cross-store-dispatch)
  - [Initial Effects](#initial-effects)
  - [Async Effects](#async-effects)
- [Derived State in Depth](#derived-state-in-depth)
  - [Dependency Tracking](#dependency-tracking)
  - [Update Compression — Diamond Problem](#update-compression--diamond-problem)
  - [Automatic Scope Promotion](#automatic-scope-promotion)
- [Scope Lifecycle and Forking](#scope-lifecycle-and-forking)
- [Event Binding — Global and Semi-Global Events](#event-binding--global-and-semi-global-events)

---

## Installation

```yaml
dependencies:
  caffeine: ^2.0.0
```

```dart
import 'package:caffeine/caffeine.dart';
```

---

## Quick Start

Define events and stores at the top level:

```dart
final increment = Event<void>();
final decrement = Event<void>();

final counterStore = Store<int>.accum((ctx) {
  ctx.on(increment, (_) async* { yield ctx.current + 1; });
  ctx.on(decrement, (_) async* { yield ctx.current - 1; });
  return 0;
});

final doubledCount = Store<int>.derive(
  (source) => counterStore(source) * 2,
);
```

Run them through a `Scope`:

```dart
final scope = Scope();

print(scope.read(counterStore));  // 0
print(scope.read(doubledCount));  // 0

\1(\2);
await Future.microtask(() {});

print(scope.read(counterStore));  // 1
print(scope.read(doubledCount));  // 2

scope.stream(counterStore).listen(print);  // prints on every change
```

---

## Core Concepts

### Event

`Event<T>` is a globally declared signal carrying a value of type `T`. Events are plain Dart objects — define them once at the top level and fire them through any scope:

```dart
final increment  = Event<void>();
final setName    = Event<String>();
final loadUser   = Event<int>();    // carries a user ID
```

`Event<T>` also implements `StoreOverride`, meaning events can be placed in scope `overrides` to control their routing. See [Event Binding](#event-binding--global-and-semi-global-events).

The `EventSourceX` extension makes every `Event<T>` callable as a shorthand for `scope.fire(event, value)`:

```dart
\1(\2);   // preferred — same as scope.\1(\2)
setName(scope, 'Alice');  // preferred — same as scope.fire(setName, 'Alice')
```

---

### Store.accum — Stateful Stores

`Store<T>.accum` is a stateful store. Its body runs once at initialization to register event handlers and return the initial state:

```dart
final counterStore = Store<int>.accum((ctx) {
  ctx.on(increment, (_) async* { yield ctx.current + 1; });
  ctx.on(decrement, (_) async* { yield ctx.current - 1; });
  ctx.on(reset, (_) async* { yield 0; });
  return 0;  // initial state
});
```

The `ctx` parameter is a `StoreAcc<T>` with four capabilities:

| Member | Description |
|---|---|
| `T get current` | Current state value. |
| `void on<E>(Event<E>, Stream<T> Function(E))` | Register an event handler. The handler is an `async*` generator that yields new states and/or fires further events. |
| `void fire<V>(Event<V>, V)` | Fire an event on any store from within a handler. |
| `V read<V>(Store<V>)` | Read another store's current value. |

---

### Store.derive — Derived State

`Store<T>.derive` computes a value from other stores. It re-evaluates automatically whenever its dependencies change:

```dart
final doubledCount = Store<int>.derive(
  (source) => counterStore(source) * 2,
);

final userGreeting = Store<String>.derive(
  (source) => 'Hello, ${userStore(source).name}!',
);
```

The `source` parameter is a `StateSource`. The `StateSourceX` extension makes every `Store<T>` callable as a shorthand:

```dart
source.read(counterStore)   // explicit
counterStore(source)        // preferred shorthand via StateSourceX extension
```

Pass `listen: false` to read a value without registering a dependency:

```dart
final snapshot = Store<String>.derive((source) {
  final flag = flagStore(source);                    // dependency: rebuilds when flag changes
  final count = counter(source, listen: false).count; // no dependency: count changes don't trigger recompute
  return flag ? 'count is $count' : 'hidden';
});
```

---

### Scope — The Runtime

`Scope` manages the reactive graph, processes events, and controls store lifecycles:

```dart
final scope = Scope();
```

| Method | Description |
|---|---|
| `scope.read(store)` | Read the current value of a store. Initializes it on first access. |
| `scope.fire(event, value)` | Fire an event. Triggers all registered handlers in scope. |
| `scope.stream(store)` | Returns a `Stream<T>` that emits on every value change. |
| `scope.fork({StoreOverrides overrides})` | Create a child scope (see [Scope Forking](#scope-lifecycle-and-forking)). |
| `scope.dispose()` | Dispose the scope and all its children. |

---

### StoreOverrides

`StoreOverrides` is `Set<StoreOverride>`. Three things implement `StoreOverride`:

**`Store<T>` directly** — binds the store to this scope. Its instance lives and dies with the scope:

```dart
scope.fork(overrides: {counterStore})
```

**`MappingStoreOverride<T>`** — redirects reads of one store to another within this scope and its descendants:

```dart
scope.fork(overrides: {
  MappingStoreOverride(from: realApiStore, to: fakeApiStore),
})
```

**`Event<T>` directly** — binds the event to this scope for broadcast routing (see [Event Binding](#event-binding--global-and-semi-global-events)):

```dart
Scope(overrides: {globalSaveEvent})
```

---

## Managed Effects

### Handling Events

Event handlers are registered via `ctx.on`. The second argument is a function `(E value) async* { ... }` that yields new states:

```dart
final counterStore = Store<int>.accum((ctx) {
  ctx.on(setValue, (newValue) async* {
    yield newValue;  // replace state entirely
  });
  ctx.on(increment, (_) async* {
    yield ctx.current + 1;  // derive from current state
  });
  return 0;
});
```

A handler can yield multiple states — each yield is a separate state transition:

```dart
ctx.on(loadUser, (id) async* {
  yield const UserState.loading();
  final user = await userRepository.get(id);
  yield UserState.loaded(user);
});
```

Yielding nothing is fine — the handler runs for side effects only:

```dart
ctx.on(logEvent, (message) async* {
  print('[LOG] $message');
  // no yield — state unchanged
});
```

---

### Cross-Store Dispatch

Use the event shorthand to dispatch events to other stores from within a handler:

```dart
final authStore = Store<AuthState>.accum((ctx) {
  ctx.on(signIn, (credentials) async* {
    yield const AuthState.loading();
    final token = await authService.signIn(credentials);
    analyticsEvent(ctx, 'user_signed_in');
    yield AuthState.authenticated(token);
  });
  return const AuthState.unauthenticated();
});
```

---

### Initial Effects

Fire events during store initialization to trigger startup work:

```dart
final configStore = Store<Config>.accum((ctx) {
  ctx.on(loadConfig, (_) async* {
    final config = await configService.load();
    yield config;
  });

  \1(\2);  // fires immediately on init
  return Config.empty();
});
```

---

### Async Effects

Handlers are `async*` generators — `await` is supported anywhere between yields:

```dart
ctx.on(submit, (_) async* {
  yield state.copyWith(submitting: true);

  try {
    final result = await api.submit(state.data);
    showSnackbar(ctx, 'Saved!');
    yield state.copyWith(submitting: false, saved: true, result: result);
  } catch (e) {
    yield state.copyWith(submitting: false, error: e.toString());
  }
});
```

---

## Derived State in Depth

### Dependency Tracking

When a `Store.derive` body reads a dependency via `dep(source)`, the runtime records `dep` as a dependency. From that point on, whenever `dep`'s value changes, the derived store is marked stale and recomputed on next read (or immediately if something is streaming it).

Dependencies are recorded fresh on each evaluation, so conditional dependencies work correctly:

```dart
final result = Store<String>.derive((source) {
  final useA = flagStore(source);
  // Only one of storeA or storeB is a dependency at a time:
  return useA ? storeA(source) : storeB(source);
});
```

---

### Update Compression — Diamond Problem

When a shared dependency changes, all derived nodes that depend on it (directly or transitively) are recomputed in topological order — each **at most once**, regardless of how many upstream paths lead to it:

```dart
final user = Store<User>.accum(/* ... */);

final firstName = Store<String>.derive((s) => user(s).firstName.toUpperCase());
final lastName  = Store<String>.derive((s) => user(s).lastName.toUpperCase());

// When user changes, fullName recomputes exactly once — not twice.
final fullName = Store<String>.derive(
  (s) => '${firstName(s)} ${lastName(s)}',
);
```

This "glitch-free" property means no intermediate inconsistent states are ever observed.

---

### Automatic Scope Promotion

When a derived store is first read, it is automatically placed in the **deepest scope that owns its dependencies** — not necessarily the scope that first reads it. This means all reads of the same derived store share a single instance within the relevant scope subtree:

```dart
// counterStore is bound to childScope
final child = root.fork(overrides: {counterStore});

// doubledCount is automatically placed alongside counterStore in childScope,
// even if it is first read from a grandchild scope.
final doubledCount = Store<int>.derive((s) => counterStore(s) * 2);

final grand = child.fork();
grand.read(doubledCount); // returns the instance in childScope
child.read(doubledCount); // same instance, cached result
```

---

## Scope Lifecycle and Forking

**Unbound stores** (not in any scope's overrides) are instantiated on the **root scope** and live for the lifetime of the application.

**Bound stores** (passed in a scope's overrides) are instantiated on that scope and disposed with it.

```dart
final root  = Scope();
final child = root.fork(overrides: {counterStore});

// counterStore lives in child, not root.
\1(\2);
await Future.microtask(() {});

child.dispose(); // counterStore is disposed here; root is unaffected.
```

**`MappingStoreOverride`** redirects store reads within a scope without affecting the original:

```dart
final testScope = Scope(overrides: {
  MappingStoreOverride(from: apiStore, to: fakeApiStore),
});
// All reads of apiStore within testScope transparently return fakeApiStore.
```

**Scope trees** propagate disposal downward. Disposing a parent disposes all children and their bound stores:

```dart
root.dispose(); // disposes child, grand, and all their stores.
```

---

## Event Binding — Global and Semi-Global Events

By default, `scope.fire(event, value)` broadcasts from the **root scope**, reaching every handler in the tree — consistent with how unbound stores are globally accessible. Binding an event to a scope narrows the broadcast to that scope's subtree.

**Binding to root** (explicit, equivalent to the default but documents intent):

```dart
final resetAll = Event<void>();

final root = Scope(overrides: {resetAll});

final leftScope  = root.fork(overrides: {counterStore});
final rightScope = root.fork(overrides: {counterStore});

\1(\2);  // broadcasts to all descendants
```

**Firing from a descendant** routes to the owning scope and broadcasts:

```dart
final grandChild = leftScope.fork();
\1(\2);  // routes to root, broadcasts to all descendants
```

**Binding to an intermediate scope** makes the event semi-global — it broadcasts only within that scope's subtree:

```dart
final localReset = Event<void>();

// localReset only broadcasts within leftScope and its children.
final leftScope = root.fork(overrides: {counterStore, localReset});
\1(\2);  // rightScope is unaffected
```

**Unbound events** broadcast from root, so all scopes in the tree receive them.

For `Event<void>`, the call form takes no second argument — write `localReset(leftScope)` instead of `localReset(leftScope, null)`.
