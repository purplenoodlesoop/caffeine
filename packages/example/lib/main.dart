import 'package:caffeine/caffeine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_caffeine/flutter_caffeine.dart';

// ── Counter store ─────────────────────────────────────────────────────────────

sealed class CounterEvent {}

class Increment extends CounterEvent {}

final counterStore = Store<int, CounterEvent>(
  (self) => (
    () => (0, Stream.empty),
    (event, state) => switch (event) {
      Increment() => (state + 1, Stream.empty),
    },
  ),
);

final doubledCounterValue = Stateful<int>(($) => $(counterStore) * 2);

// ── App ───────────────────────────────────────────────────────────────────────

void main() {
  runApp(Caffeine(scopeFactory: (context) => Scope(), child: const MyApp()));
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
      appBar: AppBar(title: const Text('Counters')),
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

// ── Counter feature ───────────────────────────────────────────────────────────

class CounterFeature extends StatelessWidget {
  const CounterFeature({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Caffeine(
      scopeFactory: (context) =>
          Caffeine.of(context).fork(references: {counterStore}),
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
                onPressed: () => context.fire(counterStore(Increment())),
                child: const Text('Increment'),
              ),
            ],
          );
        },
      ),
    );
  }
}
