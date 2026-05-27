/// Caffeine — a reactive microstore for Dart.
///
/// Defines event-driven [Store]s, lazy [Store.derive]d state with automatic
/// dependency tracking, hierarchical [Scope]s for store lifecycle management,
/// and transparent [MappingStoreOverride]s for dependency injection.
library;

export 'src/event.dart' show Event, EventSource, EventSourceX, EventVoidX, Source;
export 'src/override.dart' show StoreOverride, StoreOverrides;
export 'src/scope.dart' show Scope;
export 'src/store.dart'
    show
        AccumStoreBody,
        Concurrency,
        DerivedSource,
        DerivedStoreBody,
        MappingStoreOverride,
        StateSource,
        Store,
        StoreAcc,
        StoreReadX,
        StoreSelectX,
        StoreState;
