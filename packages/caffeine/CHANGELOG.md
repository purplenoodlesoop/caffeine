## 3.0.0 — 2026-05-27

### Breaking
- **`Event<void>` shorthand:** `signal(source)` replaces `signal(source, null)`. The shadowing extension constrains the generic variant to `T extends Object`, so events with nullable payloads (`Event<int?>`) lose the call shorthand and must use `source.fire(event, value)` directly.
- **`Store<T>` no longer implements `Event<T>`.** `ctx.on(otherStore, ...)` was always meaningless and now fails to compile. Both `Store` and `Event` still implement `StoreOverride` independently, so the overrides API is unchanged.
- **`Scope.read` / `StoreAcc.read` reject `listen: false`.** The flag was a silent no-op outside derived store bodies; passing it now throws `ArgumentError`. `listen: false` remains valid inside `Store.derive` recording.
- **`StoreState.on` throws on duplicate registration.** Previously a second `ctx.on(event, ...)` for the same event silently overwrote the prior handler.
- **Operations on a disposed scope throw `StateError`.** `read`, `fire`, `stream`, `fork`, `listen` all check `isDisposed` first.
- **`Event<T>` is now `final` and accepts `debugLabel`.** Subclassing is no longer allowed.

### Added
- **Concurrency strategies for event handlers.** `ctx.on(event, handler, concurrency: ...)` accepts `Concurrency.parallel` (default — caffeine ≤ 2 semantics), `drop`, `restart`, and `queue`.
- **`StoreState.onDispose(callback)`** registers cleanup for external resources opened inside an accum body (timers, sockets, external subscriptions). Callbacks run when the owning scope is disposed.
- **Cycle detection.** Direct or indirect self-references in `Store.derive` throw `StateError` instead of overflowing the stack.
- **Debug labels.** Optional `debugLabel:` parameter on `Event(...)`, `Store.derive(...)`, and `Store.accum(...)`. Included in `toString` and cycle-detection error messages.
- **Custom equality.** Optional `equals: (a, b) => ...` parameter on `Store.derive` and `Store.accum` replaces the default `==` for change detection.
- **`Scope.listen(event, handler)`** subscribes to events without owning a store. Returns a `StreamSubscription` for cancellation.
- **`Scope.isDisposed`** plus introspection accessors `debugBoundStores`, `debugBoundEvents`, `debugChildren`.
- **`Store<T>.select((value) => slice)`** extension creates a derived projection inline.

### Fixed
- **`Scope.stream(derived)` now wires dependencies eagerly.** Previously subscribers received no events until the derived store was also read; now `stream` forces evaluation.

## 2.0.0

- **Event binding**: passing an `Event<T>` in scope `overrides` binds it to that scope; `fire()` from the owning scope or any descendant broadcasts through the entire subtree, enabling global and semi-global event routing
- **Unbound events default to root**: unbound events broadcast from the root scope, consistent with how unbound stores are globally accessible; bind an event to an intermediate scope to restrict its broadcast to that subtree
- **Automatic scope promotion**: derived stores are now placed in the deepest scope that owns their dependencies rather than the requesting scope, so all reads within a subtree share one instance
- **Constant derived stores live on root**: derived stores with no dependencies are promoted to the root scope, consistent with unbound accum stores
- `Event<T>` now implements `StoreOverride` (extracted to `override.dart` to avoid circular imports)

## 1.0.0

Initial release.

- `Store<S, E>` — reactive state machine with pure update function and explicit effect streams
- `Stateful<S>` — lazy derived reactive value with automatic dependency tracking via `Snapshot`
- `Scope` — runtime that manages the reactive graph, dispatches events, executes effects, and controls store lifecycles
- `StoreOverride` — transparent store replacement for dependency injection and testing
- Scope forking for hierarchical store lifetime management
- External stream subscriptions via `Store`'s `subscribe` parameter
- Glitch-free update compression: every `Stateful` node recomputes at most once per event cycle regardless of how many upstream dependencies changed
