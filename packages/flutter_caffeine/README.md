# flutter_caffeine

Flutter bindings for [caffeine](https://pub.dev/packages/caffeine) — a reactive microstore with managed side effects. `flutter_caffeine` attaches caffeine scopes to the widget tree and wires `Stateful` subscriptions directly into `BuildContext`, with no `StreamBuilder`s, no `dispose` overrides, and no boilerplate wrapper widgets.

---

## Table of Contents

- [Installation](#installation)
- [How It Works](#how-it-works)
- [The Caffeine Widget](#the-caffeine-widget)
  - [Root Scope Setup](#root-scope-setup)
  - [Forking into a Child Scope](#forking-into-a-child-scope)
- [Reading State in Widgets](#reading-state-in-widgets)
  - [context.state() — Subscribe and Rebuild](#contextstate--subscribe-and-rebuild)
  - [listen: false — One-Time Read](#listen-false--one-time-read)
- [Firing Events](#firing-events)
  - [context.fire() — Dispatch an Event](#contextfire--dispatch-an-event)
- [Dependency Injection and Testing](#dependency-injection-and-testing)

---

## Installation

```yaml
dependencies:
  caffeine: ^1.0.0
  flutter_caffeine: ^0.0.1
```

```dart
import 'package:caffeine/caffeine.dart';
import 'package:flutter_caffeine/flutter_caffeine.dart';
```

---

## How It Works

`flutter_caffeine` has two building blocks:

- **`Caffeine`** — a widget that creates and attaches a caffeine `Scope` to a point in the element tree, making it available to all descendant widgets. The scope is created once in `initState` via a `scopeFactory` callback and disposed automatically when the element leaves the tree.
- **`context.state(node)`** — a `BuildContext` extension that reads a `Stateful` or `Store` value from the nearest `Caffeine` ancestor. When `listen: true` (the default), the widget rebuilds automatically whenever the value changes. Subscriptions are cleaned up via a `Finalizer` on the context — no dispose logic, no leaks.
- **`context.fire(event)`** — a `BuildContext` extension that dispatches an event through the nearest `Caffeine` ancestor's scope.

---

## The Caffeine Widget

### Root Scope Setup

Place a `Caffeine` widget near the root of your app to create the root scope. The `scopeFactory` callback receives the `BuildContext` (useful for forking — see below) and returns the `Scope` to attach:

```dart
void main() {
  runApp(
    Caffeine(
      scopeFactory: (_) => Scope(),
      child: MyApp(),
    ),
  );
}
```

To apply global `StoreOverride`s for dependency injection, pass them when constructing the scope:

```dart
Caffeine(
  scopeFactory: (_) => Scope(references: {
    StoreOverride(analyticsStore, productionAnalyticsStore),
  }),
  child: MyApp(),
)
```

### Forking into a Child Scope

Use `Caffeine.of(context)` inside `scopeFactory` to fork a child scope from the parent. Stores bound to the child scope live only as long as the `Caffeine` widget:

```dart
// Wraps a screen — screenStore is disposed when the screen leaves the tree
Caffeine(
  scopeFactory: (context) => Caffeine.of(context).fork(references: {
    screenStore,
  }),
  child: ScreenWidget(),
)
```

Because `scopeFactory` receives the `BuildContext` at `initState` time, it can traverse any number of ancestor scopes before forking:

```dart
Caffeine(
  scopeFactory: (context) => Caffeine.of(context).fork(references: {
    modalStore,
    StoreOverride(authStore, guestAuthStore),
  }),
  child: ModalContent(),
)
```

Typical scope structure in a Flutter app:

```
Caffeine (root)      ─── overrides only, app lifetime
    │
    ├── Caffeine     ─── homeStore, home screen lifetime
    │
    └── Caffeine     ─── profileStore, avatarStore, profile screen lifetime
            │
            └── Caffeine  ─── editFormStore, edit modal lifetime
```

---

## Reading State in Widgets

### context.state() — Subscribe and Rebuild

Call `context.state(node)` inside `build` to read a `Stateful` or `Store` value. With `listen: true` (the default), the widget rebuilds whenever the value changes:

```dart
class CounterDisplay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.state(counter);
    return Text('${state.count}');
  }
}
```

Subscriptions are established once per node per element and deduplicated across rebuilds. Cleanup happens via a `Finalizer` registered on the `BuildContext` — when the element leaves the tree and is garbage collected, the finalizer fires and cancels the subscription automatically.

You can read multiple nodes in one `build`. Each call independently subscribes:

```dart
Widget build(BuildContext context) {
  final user    = context.state(userStore);
  final config  = context.state(remoteConfig);
  final summary = context.state(systemState); // Stateful combining both

  return Column(children: [
    Text(user.firstName),
    Text(config.apiUrl),
    Text('${summary.doubledMessages} messages'),
  ]);
}
```

Because caffeine compresses diamond updates, `systemState` triggers at most one rebuild per event cycle even when both of its upstream stores change simultaneously.

### listen: false — One-Time Read

Pass `listen: false` to read a value without subscribing. The widget will not rebuild when the value changes:

```dart
Widget build(BuildContext context) {
  return ElevatedButton(
    onPressed: () {
      final current = context.state(counter, listen: false);
      print('Tapped with count: ${current.count}');
    },
    child: const Text('Log count'),
  );
}
```

---

## Firing Events

### context.fire() — Dispatch an Event

Call `context.fire(event)` to dispatch an event to its target store through the nearest `Caffeine` ancestor's scope:

```dart
class CounterButtons extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      IconButton(
        onPressed: () => context.fire(counter(CounterEvent.increment)),
        icon: const Icon(Icons.add),
      ),
      IconButton(
        onPressed: () => context.fire(counter(CounterEvent.decrement)),
        icon: const Icon(Icons.remove),
      ),
    ]);
  }
}
```

---

## Dependency Injection and Testing

`StoreOverride` replaces one store with another within the scope's subtree. Any `context.state(originalStore)` call inside that subtree transparently reads from the replacement:

```dart
await tester.pumpWidget(
  Caffeine(
    scopeFactory: (_) => Scope(references: {
      StoreOverride(analyticsStore, fakeAnalyticsStore),
      StoreOverride(apiStore, mockApiStore),
    }),
    child: FeatureWidget(),
  ),
);
```

`FeatureWidget` and everything inside it requires no modification — the override is fully transparent.
