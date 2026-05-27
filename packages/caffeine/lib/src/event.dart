import 'override.dart';

/// A typed event signal. Identity-compared — equal `Event` instances must be
/// the same object reference.
///
/// Events drive all state transitions: a [Store] subscribes to events via
/// `ctx.on(event, handler)` inside its body, and any [EventSource] (a [Scope]
/// or an accum [StoreState]) dispatches them via [EventSource.fire].
///
/// Events can also be bound to a scope by passing them in `Scope` overrides,
/// at which point firing the event from anywhere in the scope's subtree
/// broadcasts the event through that subtree.
///
/// An optional [debugLabel] is included in [toString] for diagnostics. It does
/// not affect identity.
final class Event<T> implements StoreOverride {
  const Event({this.debugLabel});

  /// Optional label included in diagnostic output; ignored for identity.
  final String? debugLabel;

  @override
  String toString() =>
      debugLabel != null ? 'Event<$T>($debugLabel)' : 'Event<$T>';
}

/// Anything that can dispatch an [Event] — implemented by [Scope] and the
/// accum [StoreState] context.
abstract interface class EventSource {
  void fire<T>(Event<T> event, T value);
}

/// Sugar: `event(source, value)` is short for `source.fire(event, value)`.
///
/// Constrained to `T extends Object` so that `Event<void>` resolves to the
/// arg-less [EventVoidX.call] shorthand instead of being ambiguous.
extension EventSourceX<T extends Object> on Event<T> {
  void call(EventSource source, T value) => source.fire(this, value);
}

/// Sugar for void events: `signal(source)` is short for
/// `source.fire(signal, null)`.
extension EventVoidX on Event<void> {
  void call(EventSource source) => source.fire(this, null);
}
