/// Marker interface for anything that can appear in a [Scope]'s `overrides`
/// set: a [Store] (binds the store to that scope), an [Event] (binds the event
/// for broadcast routing), or a [MappingStoreOverride] (substitutes one store
/// for another within the scope subtree).
abstract interface class StoreOverride {}

/// Set of overrides passed to `Scope()` / `Scope.fork()`.
typedef StoreOverrides = Set<StoreOverride>;
