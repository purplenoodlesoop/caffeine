## 2.0.0

- **Event binding**: passing an `Event<T>` in scope `overrides` binds it to that scope; `fire()` from the owning scope or any descendant broadcasts through the entire subtree, enabling global and semi-global event routing
- **Automatic scope promotion**: derived stores are now placed in the deepest scope that owns their dependencies rather than the requesting scope, so all reads within a subtree share one instance
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
