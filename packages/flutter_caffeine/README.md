# flutter_caffeine

Flutter bindings for [caffeine](https://pub.dev/packages/caffeine). Attaches reactive scopes to the widget tree and exposes state reads and event dispatch directly on `BuildContext` — no `StreamBuilder`s, no `dispose` overrides, no wrapper widgets.

---

## Table of Contents

- [Installation](#installation)
- [The Caffeine Widget](#the-caffeine-widget)
  - [Root Scope Setup](#root-scope-setup)
  - [Forking a Child Scope](#forking-a-child-scope)
- [Reading State in Widgets](#reading-state-in-widgets)
  - [context.state() — Subscribe and Rebuild](#contextstate--subscribe-and-rebuild)
  - [listen: false — One-Time Read](#listen-false--one-time-read)
- [Firing Events](#firing-events)
- [Dependency Injection and Testing](#dependency-injection-and-testing)

---

## Installation

```yaml
dependencies:
  caffeine: ^2.0.0
  flutter_caffeine: ^1.0.0
```

```dart
import 'package:caffeine/caffeine.dart';
import 'package:flutter_caffeine/flutter_caffeine.dart';
```

---

## The Caffeine Widget

`Caffeine` creates a caffeine `Scope` and attaches it to a point in the element tree. The scope is created once (in `initState`) via the `scopeFactory` callback and disposed automatically when the element is removed from the tree.

### Root Scope Setup

Place a `Caffeine` widget near the root of your app to create the root scope:

```dart
void main() {
  runApp(
    Caffeine(
      scopeFactory: (_) => Scope(),
      child: const MyApp(),
    ),
  );
}
```

Pass `overrides` to inject stores or bind global events:

```dart
Caffeine(
  scopeFactory: (_) => Scope(overrides: {
    MappingStoreOverride(from: apiStore, to: productionApiStore),
    globalSaveEvent,  // bound here — fires broadcast to all descendants
  }),
  child: const MyApp(),
)
```

### Forking a Child Scope

Use `Caffeine.of(context)` inside `scopeFactory` to fork a child scope. Stores bound to the child live only as long as that `Caffeine` widget:

```dart
// screenStore is disposed when this widget leaves the tree.
Caffeine(
  scopeFactory: (context) => Caffeine.of(context).fork(overrides: {
    screenStore,
  }),
  child: const ScreenWidget(),
)
```

Typical scope structure in a Flutter app:

```
Caffeine (root)        ─── global overrides, app lifetime
    │
    ├── Caffeine       ─── homeStore, home screen lifetime
    │
    └── Caffeine       ─── profileStore, profile screen lifetime
            │
            └── Caffeine  ─── editFormStore, edit modal lifetime
```

---

## Reading State in Widgets

### context.state() — Subscribe and Rebuild

Call `context.state(store)` inside `build`. When `listen: true` (the default), the widget rebuilds automatically whenever the store's value changes:

```dart
class CounterDisplay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final count = context.state(counterStore);
    return Text('$count');
  }
}
```

You can read multiple stores in a single `build`. Each call subscribes independently:

```dart
Widget build(BuildContext context) {
  final user    = context.state(userStore);
  final doubled = context.state(doubledCounterValue);

  return Column(children: [
    Text(user.name),
    Text('$doubled'),
  ]);
}
```

Subscriptions are established once per store per element and deduplicated across rebuilds. Cleanup happens via a `Finalizer` on the element — when it leaves the tree and is garbage collected, subscriptions cancel automatically. No `dispose` overrides needed.

### listen: false — One-Time Read

Pass `listen: false` to read a value without subscribing. The widget will not rebuild when the value changes:

```dart
Widget build(BuildContext context) {
  return ElevatedButton(
    onPressed: () {
      final count = context.state(counterStore, listen: false);
      print('Current count: $count');
    },
    child: const Text('Log'),
  );
}
```

---

## Firing Events

Call `context.fire(event, value)` to dispatch an event through the nearest `Caffeine` ancestor's scope:

```dart
class CounterButtons extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      IconButton(
        onPressed: () => context.fire(increment, null),
        icon: const Icon(Icons.add),
      ),
      IconButton(
        onPressed: () => context.fire(decrement, null),
        icon: const Icon(Icons.remove),
      ),
    ]);
  }
}
```

If the event is bound to an ancestor scope, the fire automatically routes there and broadcasts through the subtree — no extra wiring needed.

---

## Dependency Injection and Testing

`MappingStoreOverride` replaces one store with another within a scope's subtree. Any `context.state(originalStore)` call inside transparently reads from the replacement:

```dart
await tester.pumpWidget(
  Caffeine(
    scopeFactory: (_) => Scope(overrides: {
      MappingStoreOverride(from: apiStore, to: fakeApiStore),
    }),
    child: const FeatureWidget(),
  ),
);
```

`FeatureWidget` requires no modification — the override is fully transparent.

To isolate a store to a single widget subtree (e.g., multiple independent counters on the same screen), fork a scope with the store bound:

```dart
class CounterFeature extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Caffeine(
      scopeFactory: (context) =>
          Caffeine.of(context).fork(overrides: {counterStore}),
      child: Builder(
        builder: (context) {
          final count   = context.state(counterStore);
          final doubled = context.state(doubledCounterValue);
          // doubledCounterValue auto-promotes to live alongside counterStore.
          return Column(/* ... */);
        },
      ),
    );
  }
}
```
