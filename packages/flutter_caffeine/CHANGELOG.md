## 0.0.1

Initial release.

- `Caffeine` widget — attaches a caffeine `Scope` to a point in the element tree and disposes it when the element is removed
- `context.state(node)` — reads a `Stateful` or `Store` value from the nearest `Caffeine` ancestor; subscribes to automatic rebuilds when `listen: true` (the default)
- `context.fire(event)` — dispatches an event through the nearest `Caffeine` ancestor's scope
- `Caffeine.of(context)` — retrieves the nearest `Scope` for forking child scopes
- Subscription cleanup via `Finalizer` — no `dispose` overrides or wrapper widgets required
