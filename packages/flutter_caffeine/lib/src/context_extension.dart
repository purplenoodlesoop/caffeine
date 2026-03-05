import 'dart:async';

import 'package:caffeine/caffeine.dart';
import 'package:flutter/widgets.dart';

import 'widget.dart';

// Per-element map of active subscriptions, keyed by the Stateful node.
// Expando holds entries weakly — when the element is GC'd, the entry
// is automatically eligible for collection too.
final _subscriptions = Expando<Map<Object, StreamSubscription>>('caffeine_subs');

// Finalizer fires when a context is GC'd after leaving the tree, cancelling
// any lingering subscriptions so the streams don't hold references alive.
final _finalizer = Finalizer<StreamSubscription>((sub) => sub.cancel());

extension CaffeineBuildContextX on BuildContext {
  /// Reads [node] from the nearest [Caffeine] ancestor's scope.
  ///
  /// When [listen] is `true` (the default), the widget automatically rebuilds
  /// whenever [node]'s value changes. Subscriptions are established once per
  /// node per element and deduplicated across rebuilds. Cleanup happens via a
  /// [Finalizer] when the element is garbage collected after leaving the tree —
  /// no explicit `dispose` or wrapper widget required.
  ///
  /// Pass `listen: false` to perform a one-shot read without subscribing.
  T state<T>(Stateful<T> node, {bool listen = true}) {
    final scope = Caffeine.of(this);
    if (!listen) return scope.read(node);

    final subs = _subscriptions[this] ??= {};
    if (!subs.containsKey(node)) {
      final sub = scope.stream(node).listen((_) {
        if (mounted) (this as Element).markNeedsBuild();
      });
      subs[node] = sub;
      _finalizer.attach(this, sub, detach: this);
    }

    return scope.read(node);
  }

  /// Fires [event] through the nearest [Caffeine] ancestor's scope.
  void fire<E>(Event<E> event) => Caffeine.of(this).fire(event);
}
