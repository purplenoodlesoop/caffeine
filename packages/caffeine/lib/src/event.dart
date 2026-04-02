import 'override.dart';

class Event<T> implements StoreOverride {}

abstract interface class EventSource {
  void fire<T>(Event<T> event, T value);
}

extension EventSourceX<T> on Event<T> {
  void call(EventSource source, T value) => source.fire(this, value);
}
