import 'package:meta/meta.dart';

abstract interface class EventConsumer<E> {}

@optionalTypeArgs
class Event<E> {
  final EventConsumer<E> consumer;
  final E event;
  Event(this.consumer, this.event);
}

extension EventConsumerX<E> on EventConsumer<E> {
  Event<E> call(E event) => Event(this, event);
}
