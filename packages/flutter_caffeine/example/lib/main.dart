import 'package:caffeine/caffeine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_caffeine/flutter_caffeine.dart';

const increment = Event<void>(debugLabel: 'increment');
const resetAll = Event<void>(debugLabel: 'resetAll');

final counter = Store<int>.accum((ctx) {
  ctx.on(increment, (_) async* {
    yield ctx.current + 1;
  });
  ctx.on(resetAll, (_) async* {
    yield 0;
  });
  return 0;
}, debugLabel: 'counter');

final doubled = counter.select((c) => c * 2);

void main() {
  runApp(
    Caffeine(
      // resetAll is bound to root — fires from any descendant broadcast here.
      scopeFactory: (_) => Scope(overrides: {resetAll}),
      child: const App(),
    ),
  );
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(home: const Home());
}

class Home extends StatelessWidget {
  const Home({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('caffeine'),
        actions: [
          TextButton(
            onPressed: () => context.fire(resetAll, null),
            child: const Text('Reset'),
          ),
        ],
      ),
      body: const Row(
        children: [
          Expanded(child: CounterFeature(label: 'Left')),
          VerticalDivider(width: 1),
          Expanded(child: CounterFeature(label: 'Right')),
        ],
      ),
    );
  }
}

class CounterFeature extends StatelessWidget {
  const CounterFeature({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    // Each CounterFeature owns its own counter + increment via a forked scope.
    return Caffeine(
      scopeFactory: (context) =>
          Caffeine.of(context).fork(overrides: {counter, increment}),
      child: Builder(
        builder: (context) {
          final count = context.state(counter);
          final view = context.state(doubled);
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: Theme.of(context).textTheme.headlineSmall),
                Text('count: $count'),
                Text('doubled: $view'),
                ElevatedButton(
                  onPressed: () => context.fire(increment, null),
                  child: const Text('+1'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
