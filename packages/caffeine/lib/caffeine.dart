/// Caffeine — a reactive microstore for Dart.
///
/// Defines event-driven [Store]s, lazy [Store.derive]d state with automatic
/// dependency tracking, hierarchical [Scope]s for store lifecycle management,
/// and transparent [MappingStoreOverride]s for dependency injection.
library;

export 'src/override.dart' show StoreOverride, StoreOverrides;
export 'src/scope.dart' show Scope;
export 'src/store.dart'
    show
        AccumStoreBody,
        Concurrency,
        DerivedSource,
        DerivedStoreBody,
        Event,
        EventSource,
        EventSourceX,
        EventVoidX,
        MappingStoreOverride,
        Source,
        StateSource,
        Store,
        StoreAcc,
        StoreOverrideWithX,
        StoreReadX,
        StoreSelectX,
        StoreState;
