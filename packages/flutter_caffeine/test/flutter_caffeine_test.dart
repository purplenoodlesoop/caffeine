import 'package:caffeine/caffeine.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_caffeine/flutter_caffeine.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Shared store helpers ───────────────────────────────────────────────────────

typedef CounterState = ({int count});
typedef UserState = ({String firstName, String lastName});

enum CounterEvent { increment, decrement, reset }

Store<CounterState, CounterEvent> makeCounter() =>
    Store<CounterState, CounterEvent>(
      (self) => (
        () => ((count: 0), Stream.empty),
        (event, state) => switch (event) {
          CounterEvent.increment => ((count: state.count + 1), Stream.empty),
          CounterEvent.decrement => ((count: state.count - 1), Stream.empty),
          CounterEvent.reset => ((count: 0), Stream.empty),
        },
      ),
    );

Store<UserState, UserState> makeUserStore() => Store<UserState, UserState>(
      (self) => (
        () => ((firstName: 'John', lastName: 'Doe'), Stream.empty),
        (event, state) => (event, Stream.empty),
      ),
    );

// Renders state.count as plain text.
class CounterText extends StatelessWidget {
  const CounterText(this.counter, {super.key, this.listen = true});
  final Store<CounterState, CounterEvent> counter;
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
        expect(() => Caffeine.of(ctx), throwsAssertionError);
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

      // Warm up the stream before mounting so the controller exists.
      bool streamDone = false;
      scope.stream(counter).listen(null, onDone: () => streamDone = true);

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: const SizedBox(),
      ));
      expect(streamDone, false);

      // Remove the Caffeine widget — triggers _CaffeineState.dispose().
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

      scope.fire(counter(CounterEvent.increment));
      await tester.pump();

      // Scope still alive: read returns updated value.
      expect(scope.read(counter).count, 1);
    });

    testWidgets('child scope disposal does not affect parent scope',
        (tester) async {
      final parentCounter = makeCounter();
      final childCounter = makeCounter();

      final parentScope = Scope();
      final childScope = parentScope.fork(references: {childCounter});

      parentScope.fire(parentCounter(CounterEvent.increment));

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => parentScope,
        child: Caffeine(
          scopeFactory: (_) => childScope,
          child: CounterText(childCounter),
        ),
      ));

      // Remove inner Caffeine — childScope is disposed.
      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => parentScope,
        child: const SizedBox(),
      ));

      // Parent scope and its store survive.
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

    testWidgets('returns initial Stateful value', (tester) async {
      final counter = makeCounter();
      final doubled = Stateful(($) => $(counter).count * 2);
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
      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));

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

      scope.fire(counter(CounterEvent.increment));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      scope.fire(counter(CounterEvent.increment));
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('listen:true rebuilds when Stateful changes', (tester) async {
      final counter = makeCounter();
      final doubled = Stateful(($) => $(counter).count * 2);
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final v = ctx.state(doubled);
          return Text('$v', textDirection: TextDirection.ltr);
        }),
      ));
      expect(find.text('0'), findsOneWidget);

      scope.fire(counter(CounterEvent.increment));
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

      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));
      await tester.pump();

      expect(builds.length, 1); // no extra rebuilds
    });

    testWidgets('widget does not rebuild when value is unchanged', (tester) async {
      final counter = makeCounter();
      final scope = Scope();
      final builds = <int>[];

      // isPositive stays false as long as count <= 0
      final isPositive = Stateful(($) => $(counter).count > 0);

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

      // reset while already 0 — isPositive stays false, no rebuild expected
      scope.fire(counter(CounterEvent.reset));
      await tester.pump();
      expect(builds.length, 1);

      // increment — isPositive flips to true, rebuild expected
      scope.fire(counter(CounterEvent.increment));
      await tester.pump();
      expect(builds.length, 2);

      // increment again — isPositive stays true, no rebuild expected
      scope.fire(counter(CounterEvent.increment));
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

      scope.fire(c1(CounterEvent.increment));
      await tester.pump();
      expect(find.text('1,0'), findsOneWidget);

      scope.fire(c2(CounterEvent.increment));
      scope.fire(c2(CounterEvent.increment));
      await tester.pump();
      expect(find.text('1,2'), findsOneWidget);
    });
  });

  // ── 5. Subscription deduplication ────────────────────────────────────────

  group('Subscription deduplication', () {
    testWidgets('repeated builds do not create duplicate subscriptions',
        (tester) async {
      final counter = makeCounter();
      final scope = Scope();
      final builds = <int>[];

      // Trigger external rebuilds via a key.
      final notifier = ValueNotifier(0);

      await tester.pumpWidget(ValueListenableBuilder(
        valueListenable: notifier,
        builder: (_, __, ___) => Caffeine(
          scopeFactory: (_) => scope,
          child: BuildCounter(
            counter: builds,
            builder: (ctx) {
              ctx.state(counter); // subscribe each build
              return const SizedBox();
            },
          ),
        ),
      ));
      expect(builds.length, 1);

      // Force two extra rebuilds unrelated to counter
      notifier.value++;
      await tester.pump();
      notifier.value++;
      await tester.pump();
      expect(builds.length, 3); // rebuilt 3 times total

      builds.clear();

      // Now fire counter — should cause exactly 1 more rebuild, not 3+
      scope.fire(counter(CounterEvent.increment));
      await tester.pump();
      expect(builds.length, 1);
    });
  });

  // ── 6. Diamond — update compression ──────────────────────────────────────

  group('Diamond — update compression', () {
    testWidgets('widget rebuilds exactly once when diamond upstream changes',
        (tester) async {
      final user = makeUserStore();
      final upper1 = Stateful(($) => $(user).firstName.toUpperCase());
      final upper2 = Stateful(($) => $(user).lastName.toUpperCase());
      final combined = Stateful(($) => '${$(upper1)} ${$(upper2)}');

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

      scope.fire(user((firstName: 'Jane', lastName: 'Smith')));
      await tester.pump();

      expect(builds.length, 1);
    });

    testWidgets('diamond: widget reads correct combined value after update',
        (tester) async {
      final user = makeUserStore();
      final upper1 = Stateful(($) => $(user).firstName.toUpperCase());
      final upper2 = Stateful(($) => $(user).lastName.toUpperCase());
      final combined = Stateful(($) => '${$(upper1)} ${$(upper2)}');

      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final v = ctx.state(combined);
          return Text(v, textDirection: TextDirection.ltr);
        }),
      ));
      expect(find.text('JOHN DOE'), findsOneWidget);

      scope.fire(user((firstName: 'Jane', lastName: 'Smith')));
      await tester.pump();
      expect(find.text('JANE SMITH'), findsOneWidget);
    });

    testWidgets('subscribing to multiple diamond nodes still rebuilds once',
        (tester) async {
      final user = makeUserStore();
      final upper1 = Stateful(($) => $(user).firstName.toUpperCase());
      final upper2 = Stateful(($) => $(user).lastName.toUpperCase());
      final combined = Stateful(($) => '${$(upper1)} ${$(upper2)}');

      final scope = Scope();
      final builds = <int>[];

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: BuildCounter(
          counter: builds,
          builder: (ctx) {
            // Subscribe to all three layers of the diamond
            ctx.state(upper1);
            ctx.state(upper2);
            ctx.state(combined);
            return const SizedBox();
          },
        ),
      ));
      builds.clear();

      scope.fire(user((firstName: 'Jane', lastName: 'Smith')));
      await tester.pump();

      // markNeedsBuild is a no-op on an already-dirty element,
      // so even with 3 subscriptions there is only 1 rebuild.
      expect(builds.length, 1);
    });
  });

  // ── 7. StoreOverride ──────────────────────────────────────────────────────

  group('StoreOverride', () {
    testWidgets('override in scope is transparent to context.state',
        (tester) async {
      final real = makeCounter();
      final fake = makeCounter();

      final scope = Scope(references: {StoreOverride(real, fake)});

      // Fire into fake directly
      scope.fire(real(CounterEvent.increment));
      scope.fire(real(CounterEvent.increment));

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: CounterText(real),
      ));

      // Widget reads `real` but sees fake's state (2)
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('override in child scope does not affect parent', (tester) async {
      final real = makeCounter();
      final fake = makeCounter();

      final parent = Scope();
      parent.fire(real(CounterEvent.increment)); // real → 1

      final child = parent.fork(references: {StoreOverride(real, fake)});
      child.fire(real(CounterEvent.increment)); // fake → 1
      child.fire(real(CounterEvent.increment)); // fake → 2

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

      expect(parentRead, '1'); // sees real
      expect(childRead, '2'); // sees fake
    });

    testWidgets('context.state rebuilds correctly when override store changes',
        (tester) async {
      final real = makeCounter();
      final fake = makeCounter();

      final scope = Scope(references: {StoreOverride(real, fake)});

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: CounterText(real),
      ));
      expect(find.text('0'), findsOneWidget);

      scope.fire(real(CounterEvent.increment));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
    });
  });

  // ── 8. Scope forking and nested Caffeine ──────────────────────────────────

  group('Nested Caffeine — scope forking', () {
    testWidgets('inner widget reads from its own forked scope', (tester) async {
      final shared = makeCounter();
      final local = makeCounter();

      final parentScope = Scope();
      final childScope = parentScope.fork(references: {local});

      parentScope.fire(shared(CounterEvent.increment)); // shared → 1
      childScope.fire(local(CounterEvent.increment)); // local → 1
      childScope.fire(local(CounterEvent.increment)); // local → 2

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

      // Both counters are readable from their respective scopes.
      expect(find.text('1'), findsOneWidget); // shared
      expect(find.text('2'), findsOneWidget); // local
    });

    testWidgets(
        'inner scope store changes trigger rebuild only in inner widget',
        (tester) async {
      final shared = makeCounter();
      final local = makeCounter();

      final parentScope = Scope();
      final childScope = parentScope.fork(references: {local});

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

      childScope.fire(local(CounterEvent.increment));
      await tester.pump();

      expect(innerBuilds.length, 1); // inner rebuilt
      expect(outerBuilds.length, 0); // outer untouched
    });

    testWidgets('parent scope store changes trigger rebuild only in outer widget',
        (tester) async {
      final shared = makeCounter();
      final local = makeCounter();

      final parentScope = Scope();
      final childScope = parentScope.fork(references: {local});

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

      parentScope.fire(shared(CounterEvent.increment));
      await tester.pump();

      expect(outerBuilds.length, 1); // outer rebuilt
      expect(innerBuilds.length, 0); // inner untouched
    });
  });

  // ── 9. Firing events from widgets ────────────────────────────────────────

  group('Firing events from widget callbacks', () {
    testWidgets('fire via Caffeine.of(context) updates state and triggers rebuild',
        (tester) async {
      final counter = makeCounter();
      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final s = ctx.state(counter);
          return GestureDetector(
            onTap: () => Caffeine.of(ctx).fire(counter(CounterEvent.increment)),
            child: Text('${s.count}', textDirection: TextDirection.ltr),
          );
        }),
      ));
      expect(find.text('0'), findsOneWidget);

      await tester.tap(find.byType(GestureDetector));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.byType(GestureDetector));
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

      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));

      // Invoke the callback directly — avoids hit-test issues with a zero-sized SizedBox.
      tester.widget<GestureDetector>(find.byType(GestureDetector)).onTap!();
      expect(tappedCount, 3);
    });
  });

  // ── 10. Async effects ─────────────────────────────────────────────────────

  group('Async effects', () {
    testWidgets('effect dispatched from store update is reflected in UI',
        (tester) async {
      final store = Store<String, String>(
        (self) => (
          () => ('idle', Stream.empty),
          (event, state) => switch (event) {
            'start' => (
                'loading',
                () async* {
                  await Future.delayed(const Duration(milliseconds: 10));
                  yield self('done');
                },
              ),
            'done' => ('done', Stream.empty),
            _ => (state, Stream.empty),
          },
        ),
      );

      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final s = ctx.state(store);
          return Text(s, textDirection: TextDirection.ltr);
        }),
      ));
      expect(find.text('idle'), findsOneWidget);

      scope.fire(store('start'));
      await tester.pump();
      expect(find.text('loading'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('done'), findsOneWidget);
    });

    testWidgets('initial effect fires and updates UI after store init',
        (tester) async {
      final store = Store<int, String>(
        (self) => (
          () => (
            0,
            () async* {
              yield self('increment');
            },
          ),
          (event, state) => switch (event) {
            'increment' => (state + 1, Stream.empty),
            _ => (state, Stream.empty),
          },
        ),
      );

      final scope = Scope();

      await tester.pumpWidget(Caffeine(
        scopeFactory: (_) => scope,
        child: Builder(builder: (ctx) {
          final v = ctx.state(store);
          return Text('$v', textDirection: TextDirection.ltr);
        }),
      ));

      await tester.pump(); // let microtask run
      expect(find.text('1'), findsOneWidget);
    });
  });
}
