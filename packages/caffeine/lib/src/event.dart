import 'override.dart';

/// Anything that can be subscribed to via `ctx.on(source, handler)`.
/// Implemented by both [Event] (handler runs on every dispatch) and by
/// `Store` (handler runs on every value change, post-flush).
abstract interface class Source<T> {}

/// A typed event signal. Identity-compared — equal `Event` instances must be
/// the same object reference.
///
/// Events drive all state transitions: a store subscribes to events via
/// `ctx.on(event, handler)` inside its body, and any [EventSource] (a `Scope`
/// or an accum `StoreState`) dispatches them via [EventSource.fire].
///
/// Events can also be bound to a scope by passing them in `Scope` overrides;
/// firing the event from anywhere in the scope's subtree then broadcasts
/// through that subtree.
///
/// An optional [debugLabel] is included in [toString] for diagnostics. It does
/// not affect identity.
final class Event<T> implements Source<T>, StoreOverride {
  const Event({this.debugLabel});

  /// Optional label included in diagnostic output; ignored for identity.
  final String? debugLabel;

  @override
  String toString() =>
      debugLabel != null ? 'Event<$T>($debugLabel)' : 'Event<$T>';
}

/// Anything that can dispatch an [Event] — implemented by `Scope` and the
/// accum `StoreState` context.
abstract interface class EventSource {
  void fire<T>(Event<T> event, T value);
}

/// Sugar: `event(source, value)` is short for `source.fire(event, value)`.
///
/// This extension is on [Event] specifically — not on [Source] — so calling
/// a `Store` like `someStore(source, value)` does not compile. Stores are
/// immutable from outside; their state only changes through their own
/// event handlers.
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
