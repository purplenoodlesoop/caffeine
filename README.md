# caffeine

A reactive microstore ecosystem for Dart and Flutter with managed side effects.

| Package | Description | Version |
|---|---|---|
| [`caffeine`](packages/caffeine) | Core pure-Dart reactive microstore | `^1.0.0` |
| [`flutter_caffeine`](packages/flutter_caffeine) | Flutter bindings for caffeine | `^0.0.1` |

---

## Overview

Caffeine gives you predictable state machines that compose cleanly. Every state transition is a pure function; every side effect is an explicit, typed value — not a hidden imperative call. The runtime executes effects; your logic only describes them.

Inspired by The Elm Architecture (TEA), caffeine brings disciplined effect management to Dart and Flutter without the boilerplate.

---

## Packages

### `caffeine`

Pure Dart. No Flutter dependency. Use it in any Dart project — CLI tools, backend services, or as the foundation for Flutter apps.

- `Store<S, E>` — state machine: pure update function + explicit effect streams
- `Stateful<S>` — lazy derived state with automatic dependency tracking
- `Scope` — runtime: processes events, propagates reactivity, manages store lifecycles
- Glitch-free diamond update compression (each node recomputes at most once per event cycle)

[Read the full docs](packages/caffeine/README.md)

### `flutter_caffeine`

Flutter bindings that attach caffeine scopes to the widget tree with zero boilerplate:

- `Caffeine` widget — binds a `Scope` to a subtree and ties its lifetime to the element
- `context.state(node)` — reads a `Stateful` or `Store` and subscribes to rebuilds; no `StreamBuilder`, no `dispose`

[Read the full docs](packages/flutter_caffeine/README.md)

---

## Quick Example

```dart
// Define a store
typedef CounterState = ({int count});
enum CounterEvent { increment, decrement }

final counter = Store<CounterState, CounterEvent>(
  (self) => (
    () => ((count: 0), Stream.empty),
    (event, state) => switch (event) {
      CounterEvent.increment => ((count: state.count + 1), Stream.empty),
      CounterEvent.decrement => ((count: state.count - 1), Stream.empty),
    },
  ),
);

// Use it in Flutter
class CounterWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.state(counter);
    return Column(children: [
      Text('${state.count}'),
      ElevatedButton(
        onPressed: () => context.fire(counter(CounterEvent.increment)),
        child: const Text('+'),
      ),
    ]);
  }
}
```

---

## License

MIT — see [LICENSE](packages/caffeine/LICENSE)
