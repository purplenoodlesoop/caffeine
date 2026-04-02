import 'package:caffeine/caffeine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_caffeine/flutter_caffeine.dart';

// ── App ───────────────────────────────────────────────────────────────────────

void main() {
  runApp(
    Caffeine(
      scopeFactory: (context) => Scope(overrides: {resetAll}),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Caffeine Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const InitialScreen(),
    );
  }
}

// ── Initial screen ────────────────────────────────────────────────────────────

class InitialScreen extends StatelessWidget {
  const InitialScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Caffeine Example')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const CounterScreen())),
          child: const Text('Go to Counter Screen'),
        ),
      ),
    );
  }
}

// ── Counter screen ────────────────────────────────────────────────────────────

class CounterScreen extends StatelessWidget {
  const CounterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Counters'),
        actions: [
          TextButton(
            onPressed: () => context.fire(resetAll, null),
            child: const Text('Reset All'),
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

// ── Counter store ─────────────────────────────────────────────────────────────

final increment = Event<void>();
final resetAll = Event<void>();

final counterStore = Store<int>.accum((ctx) {
  const initial = 0;

  ctx
    ..on(increment, (_) async* {
      yield ctx.current + 1;
    })
    ..on(resetAll, (_) async* {
      yield initial;
    });

  return initial;
});

final doubledCounterValue = Store<int>.derive(
  (source) => counterStore(source) * 2,
);

// ── Counter feature ───────────────────────────────────────────────────────────

class CounterFeature extends StatelessWidget {
  const CounterFeature({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Caffeine(
      scopeFactory: (context) =>
          Caffeine.of(context).fork(overrides: {counterStore}),
      child: Builder(
        builder: (context) {
          final count = context.state(counterStore);
          final doubled = context.state(doubledCounterValue);

          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              Text(
                'Count: $count',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                'Doubled: $doubled',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.fire(increment, null),
                child: const Text('Increment'),
              ),
            ],
          );
        },
      ),
    );
  }
}
