/// Marker interface for things that can be passed to a [Scope]'s references.
///
/// Two types implement this:
/// - [Store] — binds a store's lifetime to a scope.
/// - [StoreOverride] — replaces one store with another within a scope.
abstract interface class StoreReference {}
