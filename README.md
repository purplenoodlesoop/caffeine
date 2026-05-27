# caffeine

A reactive microstore ecosystem for Dart and Flutter.

| Package | Description | Version |
|---|---|---|
| [`caffeine`](packages/caffeine) | Pure Dart reactive microstore | `^3.0.0` |
| [`flutter_caffeine`](packages/flutter_caffeine) | Flutter bindings for caffeine | `^3.0.0` |

---

## Overview

Caffeine gives you predictable, composable state machines. Every state transition is driven by a typed event; every side effect is an explicit async stream; derived values propagate automatically and efficiently.

Key properties:

- **Event-driven state** — stores update only in response to typed `Event<T>` signals
- **Explicit effects** — handlers are `async*` generators; yielding new states and firing events are the only side effects
- **Lazy derived state** — `Store.derive` recomputes automatically when dependencies change
- **Glitch-free reactivity** — diamond-shaped dependency graphs never cause redundant recomputations
- **Hierarchical scopes** — store lifetimes are tied to scope trees; forking a scope isolates store instances
- **Event broadcasting** — binding an event to a scope makes `fire()` broadcast to all descendants (global and semi-global routing)

---

## Packages

### `caffeine`

Pure Dart. No Flutter dependency. Use in any Dart project — CLI tools, backend services, or as the core of a Flutter app.

- `Event<T>` — typed event signal
- `Store<T>.accum` — stateful store with `async*` event handlers
- `Store<T>.derive` — lazy derived value with automatic dependency tracking
- `Scope` — runtime: event dispatch, reactivity propagation, store lifecycle management

[Full documentation →](packages/caffeine/README.md)

### `flutter_caffeine`

Flutter bindings that attach caffeine scopes to the widget tree with zero boilerplate:

- `Caffeine` widget — binds a `Scope` to a subtree, tied to the element's lifetime
- `context.state(store)` — reads a store and subscribes to automatic rebuilds
- `context.fire(event, value)` — dispatches an event through the nearest scope

[Full documentation →](packages/flutter_caffeine/README.md)

---

## Quick Example

```dart
// ── Stores ────────────────────────────────────────────────────────────────────

const increment = Event<void>(debugLabel: 'increment');
const resetAll  = Event<void>(debugLabel: 'resetAll');

final counterStore = Store<int>.accum((ctx) {
  ctx.on(increment, (_) async* { yield ctx.current + 1; });
  ctx.on(resetAll,  (_) async* { yield 0; });
  return 0;
}, debugLabel: 'counter');

final doubledCount = counterStore.select((c) => c * 2);

// ── Flutter ───────────────────────────────────────────────────────────────────

void main() {
  runApp(
    // Bind resetAll to root so fire() broadcasts to all child scopes.
    Caffeine(
      scopeFactory: (_) => Scope(overrides: {resetAll}),
      child: const MyApp(),
    ),
  );
}

class CounterFeature extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Caffeine(
      // Each CounterFeature gets its own isolated counterStore instance.
      scopeFactory: (context) =>
          Caffeine.of(context).fork(overrides: {counterStore}),
      child: Builder(
        builder: (context) {
          final count   = context.state(counterStore);
          final doubled = context.state(doubledCount);
          return Column(children: [
            Text('Count: $count  Doubled: $doubled'),
            ElevatedButton(
              onPressed: () => increment(Caffeine.of(context)),
              child: const Text('Increment'),
            ),
          ]);
        },
      ),
    );
  }
}
```

---

## License

MIT — see [LICENSE](packages/caffeine/LICENSE)
