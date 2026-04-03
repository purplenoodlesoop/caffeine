import 'package:caffeine/caffeine.dart';
import 'package:flutter/widgets.dart';

import 'inherited.dart';

/// Attaches a caffeine [Scope] to a point in the element tree and ties the
/// scope's lifetime to this widget. All descendants can read state via
/// [BuildContext.state] or look up the scope via [Caffeine.of].
///
/// [scopeFactory] is called once in [initState] with the current [BuildContext],
/// allowing the scope to be forked from a parent [Caffeine] ancestor via
/// `Caffeine.of(context).fork(...)`.
///
/// When this widget is removed from the tree, the scope is disposed — cleaning
/// up all bound stores and their streams.
class Caffeine extends StatefulWidget {
  const Caffeine({
    super.key,
    required this.scopeFactory,
    required this.child,
  });

  /// Called once to create the scope. Receives [BuildContext] so the scope
  /// can be forked from a parent [Caffeine] ancestor if needed.
  final Scope Function(BuildContext) scopeFactory;

  final Widget child;

  /// Returns the [Scope] from the nearest [Caffeine] ancestor.
  ///
  /// Does not register a rebuild dependency on the inherited widget — the
  /// [BuildContext.state] extension manages its own rebuild subscriptions.
  static Scope of(BuildContext context) {
    final inherited =
        context.getInheritedWidgetOfExactType<CaffeineInherited>();
    if (inherited == null) {
      throw FlutterError(
        'No Caffeine widget found in context.\n'
        'Make sure a Caffeine widget is an ancestor of the widget that '
        'calls Caffeine.of().',
      );
    }
    return inherited.scope;
  }

  @override
  State<Caffeine> createState() => _CaffeineState();
}

class _CaffeineState extends State<Caffeine> {
  late final Scope _scope;

  @override
  void initState() {
    super.initState();
    _scope = widget.scopeFactory(context);
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CaffeineInherited(scope: _scope, child: widget.child);
  }
}
