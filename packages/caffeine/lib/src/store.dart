import 'package:meta/meta.dart';

import 'event.dart';
import 'stateful.dart';
import 'store_reference.dart';
import 'types.dart';

abstract interface class Store<S, E>
    implements EventConsumer<E>, Stateful<S>, StoreReference {
  factory Store(
    StoreBody<S, E> body, {
    Stream<E> Function(S state)? subscribe,
  }) =>
      _StoreImpl<S, E>(body, subscribeFactory: subscribe);

  /// Calls [callback] with the concrete type parameters of this store,
  /// recovering [S] and [E] for typed initialization.
  @internal
  void callTyped(void Function<S2, E2>(Store<S2, E2>) callback);

  @internal
  StoreDescription<S, E> describe();

  @internal
  Stream<E> Function(S)? get subscribeFactory;
}

class _StoreImpl<S, E> implements Store<S, E> {
  _StoreImpl(this._body, {this.subscribeFactory});

  final StoreBody<S, E> _body;

  @override
  final Stream<E> Function(S)? subscribeFactory;

  // Stateful<S>.body is not used for stores; scope uses describe() instead.
  @override
  S Function(Snapshot<S> $) get body => throw UnsupportedError('unreachable');

  @override
  void callTyped(void Function<S2, E2>(Store<S2, E2>) callback) =>
      callback<S, E>(this);

  @override
  StoreDescription<S, E> describe() => _body(this);
}
