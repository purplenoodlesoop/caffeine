## 1.0.0

Initial release.

- `Store<S, E>` — reactive state machine with pure update function and explicit effect streams
- `Stateful<S>` — lazy derived reactive value with automatic dependency tracking via `Snapshot`
- `Scope` — runtime that manages the reactive graph, dispatches events, executes effects, and controls store lifecycles
- `StoreOverride` — transparent store replacement for dependency injection and testing
- Scope forking for hierarchical store lifetime management
- External stream subscriptions via `Store`'s `subscribe` parameter
- Glitch-free update compression: every `Stateful` node recomputes at most once per event cycle regardless of how many upstream dependencies changed
