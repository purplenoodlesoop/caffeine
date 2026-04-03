import 'package:caffeine/caffeine.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_caffeine/flutter_caffeine.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Shared store helpers ───────────────────────────────────────────────────────

typedef CounterState = ({int count});

final increment = Event<void>();
final decrement = Event<void>();
final reset = Event<void>();

Store<CounterState> makeCounter() => Store<CounterState>.accum((ctx) {
      ctx.on(increment, (_) async* { yield (count: ctx.current.count + 1); });
      ctx.on(decrement, (_) async* { yield (count: ctx.current.count - 1); });
      ctx.on(reset, (_) async* { yield (count: 0); });
      return (count: 0);
    });

typedef UserState = ({String firstName, String lastName});

final setUser = Event<UserState>();

Store<UserState> makeUserStore() => Store<UserState>.accum((ctx) {
      ctx.on(setUser, (u) async* { yield u; });
      return (firstName: 'John', lastName: 'Doe');
    });

// Renders state.count as plain text.
class CounterText extends StatelessWidget {
  const CounterText(this.counter, {super.key, this.listen = true});
  final Store<CounterState> counter;
  final bool listen;

  @override
  Widget build(BuildContext context) {
    final s = context.state(counter, listen: listen);
    return Text('${s.count}', textDirection: TextDirection.ltr);
  }
}

// Wraps a builder and counts how many times build is called.
class BuildCounter extends StatelessWidget {
  const BuildCounter({super.key, required this.builder, required this.counter});
  final Widget Function(BuildContext) builder;
  final List<int> counter;

  @override
  Widget build(BuildContext context) {
    counter.add(1);
    return builder(context);
  }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  // ── 1. Caffeine.of ────────────────────────────────────────────────────────

  group('Caffeine.of', () {
    testWidgets('returns the scope passed to the widget', (tester) async {
      final scope = Scope();
      Scope? captured;

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          captured = Caffeine.of(ctx);
          return const SizedBox();
        }),
      ));

      expect(captured, same(scope));
    });

    testWidgets('nested Caffeine: inner context returns inner scope',
        (tester) async {
      final outer = Scope();
      final inner = outer.fork();
      Scope? capturedOuter, capturedInner;

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => outer,
        child: Builder(builder: (ctx) {
          capturedOuter = Caffeine.of(ctx);
          return Caffeine(
            scopeFactory: (_) => inner,
            child: Builder(builder: (ctx2) {
              capturedInner = Caffeine.of(ctx2);
              return const SizedBox();
            }),
          );
        }),
      ));

      expect(capturedOuter, same(outer));
      expect(capturedInner, same(inner));
    });

    testWidgets('asserts when no Caffeine ancestor is present', (tester) async {
      await tester.pumpWidget(Builder(builder: (ctx) {
        expect(() => Caffeine.of(ctx), throwsA(isA<FlutterError>()));
        return const SizedBox();
      }));
    });
  });

  // ── 2. Scope disposal ─────────────────────────────────────────────────────

  group('Scope disposal', () {
    testWidgets('disposes the scope when widget is removed from the tree',
        (tester) async {
      final counter = makeCounter();
      final scope = Scope();

      bool streamDone = false;
      scope.stream(counter).listen(null, onDone: () => streamDone = true);

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: const SizedBox(),
      ));
      expect(streamDone, false);

      await tester.pumpWidget(const SizedBox());
      expect(streamDone, true);
    });

    testWidgets('does not dispose scope while widget remains mounted',
        (tester) async {
      final counter = makeCounter();
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: CounterText(counter),
      ));

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();

      expect(scope.read(counter).count, 1);
    });

    testWidgets('child scope disposal does not affect parent scope',
        (tester) async {
      final parentCounter = makeCounter();
      final childCounter = makeCounter();

      final parentScope = Scope();
      final childScope = parentScope.fork(overrides: {childCounter});

      parentScope.read(parentCounter); // initialize before fire
      parentScope.fire(increment, null);
      await Future.microtask(() {});

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => parentScope,
        child: Caffeine(
          scopeFactory: (_) => childScope,
          child: CounterText(childCounter),
        ),
      ));

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => parentScope,
        child: const SizedBox(),
      ));

      expect(parentScope.read(parentCounter).count, 1);
    });
  });

  // ── 3. context.state — basic reads ───────────────────────────────────────

  group('context.state — basic reads', () {
    testWidgets('returns initial store value', (tester) async {
      final counter = makeCounter();
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: CounterText(counter),
      ));

      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('returns initial derived store value', (tester) async {
      final counter = makeCounter();
      final doubled = Store<int>.derive((s) => s.read(counter).count * 2);
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final v = ctx.state(doubled);
          return Text('$v', textDirection: TextDirection.ltr);
        }),
      ));

      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('listen:false returns current value without subscribing',
        (tester) async {
      final counter = makeCounter();
      final scope = Scope();
      scope.read(counter); // initialize before fire
      scope.fire(increment, null);
      scope.fire(increment, null);
      await Future.microtask(() {});

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: CounterText(counter, listen: false),
      ));

      expect(find.text('2'), findsOneWidget);
    });
  });

  // ── 4. context.state — reactive rebuilds ─────────────────────────────────

  group('context.state — reactive rebuilds', () {
    testWidgets('listen:true rebuilds when Store changes', (tester) async {
      final counter = makeCounter();
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: CounterText(counter),
      ));
      expect(find.text('0'), findsOneWidget);

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('listen:true rebuilds when derived Store changes', (tester) async {
      final counter = makeCounter();
      final doubled = Store<int>.derive((s) => s.read(counter).count * 2);
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final v = ctx.state(doubled);
          return Text('$v', textDirection: TextDirection.ltr);
        }),
      ));
      expect(find.text('0'), findsOneWidget);

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('listen:false never triggers a rebuild', (tester) async {
      final counter = makeCounter();
      final scope = Scope();
      final builds = <int>[];

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: BuildCounter(
          counter: builds,
          builder: (ctx) {
            ctx.state(counter, listen: false);
            return const SizedBox();
          },
        ),
      ));
      expect(builds.length, 1);

      scope.fire(increment, null);
      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();

      expect(builds.length, 1);
    });

    testWidgets('widget does not rebuild when value is unchanged', (tester) async {
      final counter = makeCounter();
      final scope = Scope();
      final builds = <int>[];

      final isPositive =
          Store<bool>.derive((s) => s.read(counter).count > 0);

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: BuildCounter(
          counter: builds,
          builder: (ctx) {
            ctx.state(isPositive);
            return const SizedBox();
          },
        ),
      ));
      expect(builds.length, 1);

      scope.fire(reset, null);
      await tester.pump();
      await tester.pump();
      expect(builds.length, 1);

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();
      expect(builds.length, 2);

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();
      expect(builds.length, 2);
    });

    testWidgets('multiple state() calls in one build each subscribe independently',
        (tester) async {
      final c1 = makeCounter();
      final c2 = makeCounter();
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final a = ctx.state(c1);
          final b = ctx.state(c2);
          return Text('${a.count},${b.count}',
              textDirection: TextDirection.ltr);
        }),
      ));
      expect(find.text('0,0'), findsOneWidget);

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();
      expect(find.text('1,1'), findsOneWidget);
    });
  });

  // ── 5. Subscription deduplication ────────────────────────────────────────

  group('Subscription deduplication', () {
    testWidgets('repeated builds do not create duplicate subscriptions',
        (tester) async {
      final counter = makeCounter();
      final scope = Scope();
      final builds = <int>[];

      final notifier = ValueNotifier(0);

      await tester.pumpWidget(ValueListenableBuilder(
        valueListenable: notifier,
        builder: (_, a, b) => Caffeine(
          scopeFactory: (_) => scope,
          child: BuildCounter(
            counter: builds,
            builder: (ctx) {
              ctx.state(counter);
              return const SizedBox();
            },
          ),
        ),
      ));
      expect(builds.length, 1);

      notifier.value++;
      await tester.pump();
      await tester.pump();
      notifier.value++;
      await tester.pump();
      await tester.pump();
      expect(builds.length, 3);

      builds.clear();

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();
      expect(builds.length, 1);
    });
  });

  // ── 6. Diamond — update compression ──────────────────────────────────────

  group('Diamond — update compression', () {
    testWidgets('widget rebuilds exactly once when diamond upstream changes',
        (tester) async {
      final user = makeUserStore();
      final upper1 =
          Store<String>.derive((s) => s.read(user).firstName.toUpperCase());
      final upper2 =
          Store<String>.derive((s) => s.read(user).lastName.toUpperCase());
      final combined = Store<String>.derive(
        (s) => '${s.read(upper1)} ${s.read(upper2)}',
      );

      final scope = Scope();
      final builds = <int>[];

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: BuildCounter(
          counter: builds,
          builder: (ctx) {
            ctx.state(combined);
            return const SizedBox();
          },
        ),
      ));
      builds.clear();

      scope.fire(setUser, (firstName: 'Jane', lastName: 'Smith'));
      await tester.pump();
      await tester.pump();

      expect(builds.length, 1);
    });

    testWidgets('diamond: widget reads correct combined value after update',
        (tester) async {
      final user = makeUserStore();
      final upper1 =
          Store<String>.derive((s) => s.read(user).firstName.toUpperCase());
      final upper2 =
          Store<String>.derive((s) => s.read(user).lastName.toUpperCase());
      final combined = Store<String>.derive(
        (s) => '${s.read(upper1)} ${s.read(upper2)}',
      );

      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final v = ctx.state(combined);
          return Text(v, textDirection: TextDirection.ltr);
        }),
      ));
      expect(find.text('JOHN DOE'), findsOneWidget);

      scope.fire(setUser, (firstName: 'Jane', lastName: 'Smith'));
      await tester.pump();
      await tester.pump();
      expect(find.text('JANE SMITH'), findsOneWidget);
    });

    testWidgets('subscribing to multiple diamond nodes still rebuilds once',
        (tester) async {
      final user = makeUserStore();
      final upper1 =
          Store<String>.derive((s) => s.read(user).firstName.toUpperCase());
      final upper2 =
          Store<String>.derive((s) => s.read(user).lastName.toUpperCase());
      final combined = Store<String>.derive(
        (s) => '${s.read(upper1)} ${s.read(upper2)}',
      );

      final scope = Scope();
      final builds = <int>[];

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: BuildCounter(
          counter: builds,
          builder: (ctx) {
            ctx.state(upper1);
            ctx.state(upper2);
            ctx.state(combined);
            return const SizedBox();
          },
        ),
      ));
      builds.clear();

      scope.fire(setUser, (firstName: 'Jane', lastName: 'Smith'));
      await tester.pump();
      await tester.pump();

      expect(builds.length, 1);
    });
  });

  // ── 7. MappingStoreOverride ───────────────────────────────────────────────

  group('MappingStoreOverride', () {
    testWidgets('override in scope is transparent to context.state',
        (tester) async {
      final real = makeCounter();
      final fake = makeCounter();

      final scope = Scope(
        overrides: {MappingStoreOverride(from: real, to: fake)},
      );

      scope.read(real); // initialize (resolves to fake)
      scope.fire(increment, null);
      scope.fire(increment, null);
      await Future.microtask(() {});

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: CounterText(real),
      ));

      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('override in child scope does not affect parent', (tester) async {
      final real = makeCounter();
      // fake uses its own event so child fires don't bleed into parent's real store
      final fakeInc = Event<void>();
      final fake = Store<CounterState>.accum((ctx) {
        ctx.on(fakeInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });

      final parent = Scope();
      parent.read(real); // initialize real in parent
      parent.fire(increment, null); // real = 1
      await Future.microtask(() {});

      final child = parent.fork(
        overrides: {MappingStoreOverride(from: real, to: fake)},
      );
      child.read(real); // initialize fake (resolved via override) in child
      child.fire(fakeInc, null); // fake = 1
      child.fire(fakeInc, null); // fake = 2
      await Future.microtask(() {});

      String? parentRead, childRead;

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => parent,
        child: Builder(builder: (pCtx) {
          parentRead = '${Caffeine.of(pCtx).read(real).count}';
          return Caffeine(
            scopeFactory: (_) => child,
            child: Builder(builder: (cCtx) {
              childRead = '${Caffeine.of(cCtx).read(real).count}';
              return const SizedBox();
            }),
          );
        }),
      ));

      expect(parentRead, '1');
      expect(childRead, '2');
    });

    testWidgets('context.state rebuilds correctly when override store changes',
        (tester) async {
      final real = makeCounter();
      final fake = makeCounter();

      final scope = Scope(
        overrides: {MappingStoreOverride(from: real, to: fake)},
      );

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: CounterText(real),
      ));
      expect(find.text('0'), findsOneWidget);

      scope.fire(increment, null);
      await tester.pump();
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
    });
  });

  // ── 8. Scope forking and nested Caffeine ──────────────────────────────────

  group('Nested Caffeine — scope forking', () {
    testWidgets('inner widget reads from its own forked scope', (tester) async {
      // Use separate events so fires in one scope don't affect the other store.
      final sharedInc = Event<void>();
      final localInc = Event<void>();
      final shared = Store<CounterState>.accum((ctx) {
        ctx.on(sharedInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });
      final local = Store<CounterState>.accum((ctx) {
        ctx.on(localInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });

      final parentScope = Scope();
      final childScope = parentScope.fork(overrides: {local});

      parentScope.read(shared); // initialize
      childScope.read(local);   // initialize
      parentScope.fire(sharedInc, null); // shared = 1
      childScope.fire(localInc, null);   // local = 1
      childScope.fire(localInc, null);   // local = 2
      await Future.microtask(() {});

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => parentScope,
        child: Column(children: [
          CounterText(shared),
          Caffeine(
            scopeFactory: (_) => childScope,
            child: CounterText(local),
          ),
        ]),
      ));

      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets(
        'inner scope store changes trigger rebuild only in inner widget',
        (tester) async {
      // local uses its own event so child fires don't reach the shared store.
      final localInc = Event<void>();
      final shared = makeCounter();
      final local = Store<CounterState>.accum((ctx) {
        ctx.on(localInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });

      final parentScope = Scope();
      final childScope = parentScope.fork(overrides: {local});

      final outerBuilds = <int>[];
      final innerBuilds = <int>[];

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => parentScope,
        child: Column(children: [
          BuildCounter(
            counter: outerBuilds,
            builder: (ctx) {
              ctx.state(shared);
              return const SizedBox();
            },
          ),
          Caffeine(
            scopeFactory: (_) => childScope,
            child: BuildCounter(
              counter: innerBuilds,
              builder: (ctx) {
                ctx.state(local);
                return const SizedBox();
              },
            ),
          ),
        ]),
      ));
      outerBuilds.clear();
      innerBuilds.clear();

      childScope.fire(localInc, null);
      await tester.pump();
      await tester.pump();

      expect(innerBuilds.length, 1);
      expect(outerBuilds.length, 0);
    });

    testWidgets('parent scope store changes trigger rebuild only in outer widget',
        (tester) async {
      // local uses its own event so parent fires don't reach the local store.
      final localInc = Event<void>();
      final shared = makeCounter();
      final local = Store<CounterState>.accum((ctx) {
        ctx.on(localInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });

      final parentScope = Scope();
      final childScope = parentScope.fork(overrides: {local});

      final outerBuilds = <int>[];
      final innerBuilds = <int>[];

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => parentScope,
        child: Column(children: [
          BuildCounter(
            counter: outerBuilds,
            builder: (ctx) {
              ctx.state(shared);
              return const SizedBox();
            },
          ),
          Caffeine(
            scopeFactory: (_) => childScope,
            child: BuildCounter(
              counter: innerBuilds,
              builder: (ctx) {
                ctx.state(local);
                return const SizedBox();
              },
            ),
          ),
        ]),
      ));
      outerBuilds.clear();
      innerBuilds.clear();

      parentScope.fire(increment, null);
      await tester.pump();
      await tester.pump();

      expect(outerBuilds.length, 1);
      expect(innerBuilds.length, 0);
    });
  });

  // ── 9. Firing events from widgets ────────────────────────────────────────

  group('Firing events from widget callbacks', () {
    testWidgets('fire via context.fire updates state and triggers rebuild',
        (tester) async {
      final counter = makeCounter();
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final s = ctx.state(counter);
          return GestureDetector(
            onTap: () => ctx.fire(increment, null),
            child: Text('${s.count}', textDirection: TextDirection.ltr),
          );
        }),
      ));
      expect(find.text('0'), findsOneWidget);

      await tester.tap(find.byType(GestureDetector));
      await tester.pump();
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.byType(GestureDetector));
      await tester.pump();
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('listen:false read inside callback returns current value',
        (tester) async {
      final counter = makeCounter();
      final scope = Scope();
      int? tappedCount;

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          return GestureDetector(
            onTap: () {
              tappedCount = ctx.state(counter, listen: false).count;
            },
            child: const SizedBox(),
          );
        }),
      ));

      scope.read(counter); // initialize before firing
      scope.fire(increment, null);
      scope.fire(increment, null);
      scope.fire(increment, null);
      await Future.microtask(() {});

      tester.widget<GestureDetector>(find.byType(GestureDetector)).onTap!();
      expect(tappedCount, 3);
    });
  });

  // ── 10. Async effects ─────────────────────────────────────────────────────

  group('Async effects', () {
    testWidgets('effect dispatched from store update is reflected in UI',
        (tester) async {
      final start = Event<void>();
      final done = Event<void>();

      final store = Store<String>.accum((ctx) {
        ctx.on(start, (_) async* {
          yield 'loading';
          await Future.delayed(const Duration(milliseconds: 10));
          ctx.fire(done, null);
        });
        ctx.on(done, (_) async* { yield 'done'; });
        return 'idle';
      });

      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final s = ctx.state(store);
          return Text(s, textDirection: TextDirection.ltr);
        }),
      ));
      expect(find.text('idle'), findsOneWidget);

      scope.fire(start, null);
      await tester.pump();
      await tester.pump();
      expect(find.text('loading'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('done'), findsOneWidget);
    });

    testWidgets('initial effect fires and updates UI after store init',
        (tester) async {
      final doIncrement = Event<void>();

      final store = Store<int>.accum((ctx) {
        ctx.on(doIncrement, (_) async* { yield ctx.current + 1; });
        ctx.fire(doIncrement, null);
        return 0;
      });

      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final v = ctx.state(store);
          return Text('$v', textDirection: TextDirection.ltr);
        }),
      ));

      await tester.pump();
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
    });
  });
}
