import 'package:caffeine/caffeine.dart';
import 'package:flutter/widgets.dart';

/// Carries a caffeine [Scope] down the element tree.
class CaffeineInherited extends InheritedWidget {
  const CaffeineInherited({super.key, required this.scope, required super.child});

  final Scope scope;

  @override
  bool updateShouldNotify(CaffeineInherited old) => scope != old.scope;
}
