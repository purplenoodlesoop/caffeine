import 'event.dart';

typedef StoreStep<S> = (S state, Stream<Event> Function() sideEffects);
typedef Handler<S, E> = StoreStep<S> Function(E event, S state);
typedef StoreDescription<S, E> = (
  StoreStep<S> Function() initial,
  Handler<S, E> update,
);
typedef StoreBody<S, E> = StoreDescription<S, E> Function(EventConsumer<E> self);
