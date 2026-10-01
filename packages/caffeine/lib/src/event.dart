part of 'store.dart';

/// Anything that can be subscribed to via `ctx.on(source, handler)`.
/// Implemented by both [Event] (handler runs on every dispatch) and by
/// `Store` (handler runs on every value change, post-flush).
///
/// Sealed: [Event] and `Store` are the only subtypes, so `ctx.on` can switch
/// over them exhaustively and no other implementation can reach it.
sealed class Source<T> {}

/// A typed event signal. Identity-compared — equal `Event` instances must be
/// the same object reference.
///
/// Declare events with `final`. The constructor is deliberately not `const`:
/// Dart canonicalizes const instances with equal arguments, so two
/// `const Event<void>()` declarations would silently be one event.
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
  Event({this.debugLabel});

  /// Optional label included in diagnostic output; ignored for identity.
  final String? debugLabel;

  @override
  String toString() =>
      debugLabel != null ? 'Event<$T>($debugLabel)' : 'Event<$T>';
}

/// Anything that can dispatch an [Event] — implemented by `Scope` and the
/// accum `StoreState` context.
abstract interface class EventSource {
  /// Dispatches [event] with [value]. The future completes once the handlers
  /// this call started have finished and their states have propagated —
  /// see `Scope.fire`.
  Future<void> fire<T>(Event<T> event, T value);
}

/// Sugar: `event(source, value)` is short for `source.fire(event, value)`.
///
/// This extension is on [Event] specifically — not on [Source] — so calling
/// a `Store` like `someStore(source, value)` does not compile. Stores are
/// immutable from outside; their state only changes through their own
/// event handlers.
///
/// Constrained to `T extends Object` so that `Event<void>` resolves to the
/// arg-less [EventVoidX.call] shorthand instead of being ambiguous. Events
/// with a nullable payload (`Event<int?>`) therefore have no two-argument
/// shorthand: fire them with `source.fire(event, value)`. A nullable variant
/// can't be added — extension resolution treats `void` and `Object?` as the
/// same type, so it would make every `Event<void>` call ambiguous.
extension EventSourceX<T extends Object> on Event<T> {
  Future<void> call(EventSource source, T value) => source.fire(this, value);
}

/// Sugar for void events: `signal(source)` is short for
/// `source.fire(signal, null)`.
///
/// Because `Event<int?>` is a subtype of `Event<void>`, this shorthand also
/// applies to nullable-payload events and fires `null`. Prefer the explicit
/// `source.fire(event, value)` for those.
extension EventVoidX on Event<void> {
  Future<void> call(EventSource source) => source.fire(this, null);
}
