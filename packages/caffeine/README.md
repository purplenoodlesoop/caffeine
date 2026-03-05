# caffeine

A reactive microstore library for Dart with managed side effects. Caffeine gives you predictable state machines that compose cleanly, where every state transition is pure and every side effect is an explicit, typed value — not a hidden imperative call.

Inspired by The Elm Architecture (TEA), caffeine brings the discipline of effect management to Dart without the boilerplate.

---

## Table of Contents

- [Core Philosophy](#core-philosophy)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
  - [Store](#store)
  - [StoreStep — State + Effects](#storestep--state--effects)
  - [Events and EventConsumer](#events-and-eventconsumer)
  - [Stateful — Derived Reactive State](#stateful--derived-reactive-state)
  - [Snapshot — Dependency Tracking](#snapshot--dependency-tracking)
  - [Scope — The Runtime](#scope--the-runtime)
  - [StoreReference and StoreOverride](#storereference-and-storeoverride)
- [Managed Side Effects](#managed-side-effects)
  - [Effects as Streams](#effects-as-streams)
  - [Cross-Store Event Dispatch](#cross-store-event-dispatch)
  - [Initial Effects](#initial-effects)
  - [Async Effects](#async-effects)
- [External Subscriptions](#external-subscriptions)
- [Composing Stores with Stateful](#composing-stores-with-stateful)
- [The Diamond Problem — Update Compression](#the-diamond-problem--update-compression)
- [Scope Lifecycle and Forking](#scope-lifecycle-and-forking)
- [Patterns and Conventions](#patterns-and-conventions)
  - [Sealed Event Hierarchies](#sealed-event-hierarchies)
  - [Self-Dispatching Stores](#self-dispatching-stores)

---

## Core Philosophy

Most state management libraries mix state transitions and side effects together, making systems hard to test and reason about. Caffeine enforces a strict separation:

- **State transitions are pure functions.** Given an event and the current state, the `update` handler returns a new state. No mutations, no async gaps.
- **Side effects are explicit values.** The `update` handler also returns a `Stream<Event>` factory — a description of what should happen next, not the execution of it. The runtime executes effects; your logic just describes them.
- **Reactivity is composable.** `Stateful` nodes let you derive new state from any combination of `Store`s and other `Stateful`s, and the runtime ensures updates propagate efficiently through the graph.

---

## Installation

Add caffeine to your `pubspec.yaml`:

```yaml
dependencies:
  caffeine: ^1.0.0
```

Then import it:

```dart
import 'package:caffeine/caffeine.dart';
```

---

## Quick Start

Here is a minimal counter store:

```dart
typedef CounterState = ({int count});

enum CounterEvent { increment, decrement, reset }

final counter = Store<CounterState, CounterEvent>(
  (self) => (
    // Initial state and initial effects
    () => ((count: 0), Stream.empty),

    // Update: pure function returning (newState, effects)
    (event, state) => switch (event) {
      CounterEvent.increment => ((count: state.count + 1), Stream.empty),
      CounterEvent.decrement => ((count: state.count - 1), Stream.empty),
      CounterEvent.reset     => ((count: 0),               Stream.empty),
    },
  ),
);
```

Read state and fire events through a `Scope`:

```dart
final scope = Scope();

// Read current state
final currentCount = scope.read(counter).count;

// Fire an event
scope.fire(counter(CounterEvent.increment));

// Stream state changes
scope.stream(counter).listen((state) {
  print('Count is now: ${state.count}');
});
```

---

## Core Concepts

### Store

`Store<S, E>` is the fundamental unit of state in caffeine. It is a self-contained state machine that:

- Holds a value of type `S` (its state).
- Accepts events of type `E`.
- Produces a new state and a stream of side effects on every event.

```dart
final store = Store<MyState, MyEvent>(
  (self) => (
    initialFactory,
    updateHandler,
  ),
);
```

The `self` parameter is the store's own `EventConsumer<E>`, used to dispatch events back to itself from within effects (see [Self-Dispatching Stores](#self-dispatching-stores)).

`Store<S, E>` implements three interfaces simultaneously:
- `Stateful<S>` — it is a reactive state node, readable by other `Stateful`s.
- `EventConsumer<E>` — it can receive events.
- `StoreReference` — it can be bound to a `Scope` to control its lifecycle.

### StoreStep — State + Effects

Every event handler in caffeine must return a `StoreStep<S>`:

```dart
typedef StoreStep<S> = (S state, Stream<Event> Function() sideEffects);
```

It is a record of two things:

1. **The new state** — the pure, immutable result of processing the event.
2. **A side-effects factory** — a zero-argument function that returns a `Stream<Event>`. The stream emits further events (targeting any store) that the runtime will dispatch. It is a factory so that the runtime controls when effects begin.

`Stream.empty` is the canonical way to express "no effects":

```dart
(event, state) => (newState, Stream.empty),
```

For actual effects, provide an `async*` function:

```dart
(event, state) => (
  newState,
  () async* {
    final result = await someAsyncOperation();
    yield self(ProcessResult(result));
  },
),
```

### Events and EventConsumer

`Event<E>` is a pairing of a target `EventConsumer<E>` and an event value `E`. You never construct it directly — the `EventConsumerX` extension makes every `EventConsumer` callable, turning it into an `Event` factory:

```dart
// counter is a Store<CounterState, CounterEvent>
// counter(CounterEvent.increment) creates an Event<CounterEvent>
scope.fire(counter(CounterEvent.increment));
```

This same syntax is used inside effect streams to target any store:

```dart
() async* {
  yield logger(LogEvent.info('Loading...'));   // targets logger store
  yield self(MyEvent.complete);               // targets this store
}
```

### Stateful — Derived Reactive State

`Stateful<S>` represents a reactive value derived from one or more other reactive nodes. Unlike `Store`, it has no events — it recomputes automatically whenever its dependencies change.

```dart
final derivedValue = Stateful(($) => /* computation using $ */);
```

The `$` parameter is a `Snapshot` — a callable object. Calling `$(someStore)` or `$(someStateful)` reads the current value **and** registers a dependency on that node. If the node changes, `derivedValue` will recompute.

```dart
final userGreeting = Stateful(
  ($) => 'Hello, ${$(user).firstName} ${$(user).lastName}!',
);
```

`Stateful` nodes are lazy: they do not compute until something reads them, and they only recompute when a dependency has actually changed.

### Snapshot — Dependency Tracking

`Snapshot<T>` is the mechanism through which `Stateful` discovers its dependencies:

```dart
abstract interface class Snapshot<T> {
  T? get current;                     // Last computed value, without registering a dependency
  A call<A>(Stateful<A> state);       // Read a node and register it as a dependency
}
```

When you write `$(someNode)` inside a `Stateful` body, you are calling `Snapshot.call(someNode)`. The runtime intercepts this call, records the dependency, and returns the current value. From that point on, whenever `someNode` updates, the runtime knows to re-run this `Stateful`'s body.

`current` provides a backdoor to read the last value without creating a dependency — useful when you want to conditionally depend on a node only in some branches of your computation.

You will never implement or instantiate `Snapshot` yourself — it is provided to `Stateful` body functions by the runtime.

### Scope — The Runtime

`Scope` is the runtime environment. It manages the reactive graph, processes events, runs effects, and governs the lifecycle of the stores registered with it.

```dart
final rootScope = Scope();
```

| Method | Description |
|---|---|
| `scope.read(node)` | Read the current value of a `Stateful` or `Store`. |
| `scope.fire(event)` | Dispatch an `Event` to its target store. |
| `scope.stream(node)` | Get a `Stream<S>` that emits every time `node`'s value changes. |
| `scope.fork(references: {...})` | Create a child scope (see [Scope Lifecycle and Forking](#scope-lifecycle-and-forking)). |

Every store accessed through a scope is instantiated on demand. Where it is instantiated — and therefore how long it lives — is determined by whether it has been bound to a scope. See [Scope Lifecycle and Forking](#scope-lifecycle-and-forking) for the full rules.

### StoreReference and StoreOverride

`StoreReference` is a sealed type that represents anything that can be passed to a scope. Two things implement it:

- **`Store<S, E>`** — binding a store to a scope means that store's instance will live and die with that scope.
- **`StoreOverride<S, E>`** — replaces one store with another within a scope. When any code inside the scope resolves the `from` store, it receives the `to` store instead.

```dart
class StoreOverride<S, E> implements StoreReference {
  final Store<S, E> from;
  final Store<S, E> to;
}
```

Overrides are the primary mechanism for dependency injection and testing. The root scope accepts only `StoreOverride`s — it exists as an injection point, not a lifecycle container. Forked scopes accept both stores and overrides.

---

## Managed Side Effects

### Effects as Streams

The core idea: **an effect is not a function that runs; it is a stream of events that will be dispatched.** The `update` handler declares *what should happen*; the runtime *makes it happen*.

This means your update logic is always a pure function:

```dart
(event, state) => (
  state.copyWith(isLoading: true),
  () async* {
    final data = await api.fetchData();
    yield self(DataLoaded(data));
  },
),
```

The runtime subscribes to the stream returned by the factory. Each yielded `Event` is dispatched through the normal event pipeline, triggering further state updates and effects.

Because the effect is a factory (a zero-argument function), the runtime decides when to start it. This makes effects cancellable, restartable, and testable: in tests you can intercept the factory and assert on what it would do without actually running it.

### Cross-Store Event Dispatch

Because effects yield `Event` objects, a store can dispatch events to **any** other store from within its own effects:

```dart
final remoteConfig = Store<RemoteConfigState, RemoteConfigEvent>(
  (self) => (
    () => (initialState, Stream.empty),
    (event, state) => switch (event) {
      LoadRemoteConfig() => (
        state,
        () async* {
          // Dispatch an event to the logger store
          yield logger((.info, 'Requesting remote config...'));

          final newValue = await fetchRemoteConfig();

          // Dispatch an event back to ourselves
          yield self(UpdateRemoteConfigState(newValue));
        },
      ),
      UpdateRemoteConfigState(data: final newState) => (newState, Stream.empty),
    },
  ),
);
```

This creates explicit, traceable cross-store communication without shared mutable state or callback chains.

### Initial Effects

The initial factory also returns a `StoreStep<S>`, so a store can dispatch events at the moment it is initialized:

```dart
final remoteConfig = Store<RemoteConfigState, RemoteConfigEvent>(
  (self) => (
    () => (
      (apiUrl: 'https://example.com/api', number: 42),
      () async* {
        yield self(const LoadRemoteConfig(()));  // fires on startup
      },
    ),
    updateHandler,
  ),
);
```

This is the idiomatic way to perform startup work: initialize with a placeholder state, then immediately fire an event that triggers the real load.

### Async Effects

Effect factories are `async*` generators, so they naturally support sequential async steps, error handling, and conditional yields:

```dart
() async* {
  yield self(SetLoading(true));

  try {
    final result = await api.call();
    yield self(DataLoaded(result));
  } catch (e) {
    yield self(DataFailed(e.toString()));
  }

  yield self(SetLoading(false));
}
```

Multiple events can be yielded from a single effect, and they are dispatched in order. Each dispatch runs through the full update → effects pipeline before the next one starts.

---

## External Subscriptions

Stores can subscribe to external streams via the `subscribe` parameter. This is how you integrate external data sources — timers, WebSockets, platform channels — into the reactive graph without manual wiring:

```dart
final remoteConfig = Store<RemoteConfigState, RemoteConfigEvent>(
  subscribe: (state) => Stream.periodic(
    const Duration(minutes: 10),
    (_) => const LoadRemoteConfig(()),
  ),
  (self) => ( ... ),
);
```

The `subscribe` function receives the current state and returns a `Stream<E>`. Every value emitted by that stream is dispatched to the store as an event, running through the normal update pipeline.

The `state` parameter allows the subscription to be dynamic — you can open different streams based on what state the store is currently in.

The runtime manages the subscription's lifecycle: it is created when the store is initialized and cancelled when the scope is disposed.

---

## Composing Stores with Stateful

`Stateful` is the glue between stores. It projects and combines state from multiple independent stores without either store knowing about the other:

```dart
final systemState = Stateful(
  ($) => (
    url: $(remoteConfig).apiUrl,
    doubledMessages: $(logger).logsCount * 2,
  ),
);
```

`systemState` will recompute automatically whenever `remoteConfig` or `logger` change. You can also chain `Stateful` nodes, creating multi-level derived graphs:

```dart
final upperCasedFirstName = Stateful(($) => $(user).firstName.toUpperCase());
final upperCasedLastName  = Stateful(($) => $(user).lastName.toUpperCase());

final upperCasedName = Stateful(
  ($) => '${$(upperCasedFirstName)} ${$(upperCasedLastName)}',
);
```

Each level is independently memoized: if `user.firstName` changes but `user.lastName` doesn't, `upperCasedLastName` will not recompute.

---

## The Diamond Problem — Update Compression

Consider the dependency graph above:

```
         user
        /    \
firstName   lastName
        \    /
         name
```

When `user` changes, both `upperCasedFirstName` and `upperCasedLastName` become stale, which means `upperCasedName` has two reasons to update. A naive reactive system would recompute `upperCasedName` twice, potentially causing double renders or double effect executions.

Caffeine solves this with **update compression**. When `user` emits a synchronous update, the runtime batches all downstream recomputations and runs each node exactly once per transaction, regardless of how many upstream dependencies changed.

```dart
/// On [user] update, [upperCasedName] will update only once, compressing sync
/// and pure [Stateful] updates
final upperCasedName = Stateful(
  ($) => '${$(upperCasedFirstName)} ${$(upperCasedLastName)}',
);
```

The runtime topologically sorts the dependency graph and processes each node at most once per event cycle. This is sometimes called "glitch-free" reactivity. You can build arbitrarily deep and wide reactive graphs without worrying about redundant recomputations or inconsistent intermediate states.

---

## Scope Lifecycle and Forking

Scopes control where store instances live and how long they last. The rules are straightforward:

**If a store is not bound to any scope**, it is instantiated on the root scope and lives for the lifetime of the application.

**If a store is bound to a scope** (passed in `references`), or if any of its dependencies are bound to a scope, it is instantiated on the nearest enclosing scope. Lifecycle propagates in one direction — from parent to child. A store bound to a child scope cannot outlive that scope, but it can freely depend on stores from any parent scope.

**The root scope** (`Scope(references: {...})`) accepts only `StoreOverride`s. It is an injection point, not a lifecycle container — its role is to replace stores globally, not to manage their lifetime.

**Forked scopes** (`scope.fork(references: {...})`) accept both `Store`s and `StoreOverride`s. They are the primary tool for managing the lifetime of stores that should only exist for part of the application — a screen, a session, a modal:

```dart
// Root scope: overrides only (dependency injection)
final rootScope = Scope(references: {
  StoreOverride(analyticsStore, mockAnalyticsStore),
});

// Forked scope: bind stores + optionally override
final screenScope = rootScope.fork(references: {
  screenStore,          // Store — bound to this scope's lifetime
  StoreOverride(authStore, guestAuthStore),  // Override — local to this scope
});
```

When `screenScope` is disposed, `screenStore` is cleaned up. Stores from `rootScope` are unaffected. A further fork of `screenScope` would inherit both the root override and the screen scope's stores:

```dart
// Inherits screenStore binding and all parent overrides
final modalScope = screenScope.fork(references: {modalStore});
```

Typical lifecycle structure:

```
rootScope  ─── overrides only
    │
    ├── homeScope   ─── homeStore
    │
    └── profileScope  ─── profileStore, avatarStore
            │
            └── editScope  ─── editFormStore
```

Each scope is independent. Disposing `profileScope` cleans up `profileStore`, `avatarStore`, and recursively `editScope` with its `editFormStore` — but leaves `homeScope` and `rootScope` untouched.

---

## Patterns and Conventions

State types must override `==` and `hashCode`. The runtime uses equality to determine whether a store's value has actually changed after an update — if the new state equals the old state, no downstream recomputations or notifications are triggered. Dart 3 records satisfy this automatically; for classes, use `package:equatable` or implement `==` and `hashCode` manually.

### Sealed Event Hierarchies

For stores with multiple event types, sealed classes give you exhaustive pattern matching in the `update` handler:

```dart
sealed class RemoteConfigEvent<T> = Union<T> with $;

final class LoadRemoteConfig        = RemoteConfigEvent<()>                  with $;
final class UpdateRemoteConfigState = RemoteConfigEvent<RemoteConfigState>   with $;

(event, state) => switch (event) {
  LoadRemoteConfig()                              => ( ... ),
  UpdateRemoteConfigState(data: final newState)   => ( ... ),
},
```

The Dart compiler enforces exhaustiveness — if you add a new event subtype, every switch that matches on the sealed type will produce a compile-time error until you handle it.

### Self-Dispatching Stores

The `self` parameter in `StoreBody` is the store's own `EventConsumer`. Use it to send events back to the store from within its effects, enabling multi-step workflows inside a single store:

```dart
final myStore = Store<MyState, MyEvent>(
  (self) => (
    () => (initialState, () async* {
      yield self(MyEvent.initialize);
    }),
    (event, state) => switch (event) {
      MyEvent.initialize => (state, () async* {
        final data = await loadData();
        yield self(MyEvent.loaded(data));
      }),
      MyEvent.loaded(:final data) => (state.withData(data), Stream.empty),
    },
  ),
);
```

This pattern keeps multi-step async flows entirely within a single store without exposing intermediate events to the outside world.
