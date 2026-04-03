## 2.0.0

Aligned with caffeine 2.0.0.

**Breaking changes:**
- `context.state(node)` — parameter type changed from `Stateful<T>` to `Store<T>`
- `context.fire(event)` — now requires an explicit value argument: `context.fire(event, value)`

**Improvements:**
- `Caffeine.of()` throws a `FlutterError` instead of asserting — error is surfaced in release mode with a descriptive message
- `CaffeineInherited` constructor forwards `key`

## 1.0.0

Initial release.

- `Caffeine` widget — attaches a caffeine `Scope` to a point in the element tree and disposes it when the element is removed
- `context.state(node)` — reads a `Stateful` or `Store` value from the nearest `Caffeine` ancestor; subscribes to automatic rebuilds when `listen: true` (the default)
- `context.fire(event)` — dispatches an event through the nearest `Caffeine` ancestor's scope
- `Caffeine.of(context)` — retrieves the nearest `Scope` for forking child scopes
- Subscription cleanup via `Finalizer` — no `dispose` overrides or wrapper widgets required
