## 3.0.0 — 2026-05-27

Aligned with caffeine 3.0.0. See its [CHANGELOG](../caffeine/CHANGELOG.md) for the underlying API changes.

### Breaking
- **Pulls in caffeine 3.0.0** — every breaking change there applies through the flutter bindings:
  - `Event<void>` instances now fire via `event(source)` instead of `event(source, null)`.
  - `Scope.read(node, listen: false)` throws; use only inside `Store.derive` bodies.
  - Disposed-scope operations throw `StateError`.
- **`flutter` SDK floor bumped** from `>=1.17.0` to `>=3.10.0`.

### Improvements
- `Caffeine.of(context)` already threw `FlutterError` in 2.0; no behavioral change here.

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
