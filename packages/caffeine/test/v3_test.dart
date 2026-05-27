import 'dart:async';

import 'package:caffeine/caffeine.dart';
import 'package:test/test.dart';

void main() {
  // ── T1: Event<void> shorthand ─────────────────────────────────────────────

  group('Event<void> shorthand', () {
    test('event(scope) fires a void event without value', () async {
      final ping = Event<void>();
      var hits = 0;
      final scope = Scope();
      scope.listen(ping, (_) => hits++);

      ping(scope);
      ping(scope);
      expect(hits, 2);
      scope.dispose();
    });

    test('typed event still requires value', () async {
      final addValue = Event<int>();
      var received = 0;
      final scope = Scope();
      scope.listen(addValue, (v) => received += v);

      addValue(scope, 3);
      addValue(scope, 4);
      expect(received, 7);
      scope.dispose();
    });
  });

  // ── G1: onDispose hook ────────────────────────────────────────────────────

  group('onDispose hook', () {
    test('callback runs when scope is disposed', () {
      var disposeCount = 0;
      final store = Store<int>.accum((ctx) {
        ctx.onDispose(() => disposeCount++);
        return 0;
      });
      final scope = Scope();
      scope.read(store);
      expect(disposeCount, 0);
      scope.dispose();
      expect(disposeCount, 1);
    });

    test('multiple onDispose callbacks run in registration order', () {
      final order = <int>[];
      final store = Store<int>.accum((ctx) {
        ctx.onDispose(() => order.add(1));
        ctx.onDispose(() => order.add(2));
        ctx.onDispose(() => order.add(3));
        return 0;
      });
      final scope = Scope();
      scope.read(store);
      scope.dispose();
      expect(order, [1, 2, 3]);
    });

    test('callback throwing does not block subsequent callbacks', () {
      var second = false;
      final store = Store<int>.accum((ctx) {
        ctx.onDispose(() => throw StateError('boom'));
        ctx.onDispose(() => second = true);
        return 0;
      });
      final scope = Scope();
      scope.read(store);
      runZonedGuarded(scope.dispose, (_, _) {});
      expect(second, true);
    });
  });

  // ── G2: Duplicate on() throws ─────────────────────────────────────────────

  group('Duplicate on() throws', () {
    test('second on(event, handler) for same event throws', () {
      final inc = Event<void>();
      final scope = Scope();
      final store = Store<int>.accum((ctx) {
        ctx.on(inc, (_) async* {});
        ctx.on(inc, (_) async* {}); // should throw
        return 0;
      });
      expect(() => scope.read(store), throwsA(isA<StateError>()));
      scope.dispose();
    });
  });

  // ── G3: Cycle detection ───────────────────────────────────────────────────

  group('Cycle detection', () {
    test('self-referential derived store throws', () {
      late Store<int> cycle;
      cycle = Store<int>.derive((s) => cycle(s) + 1);
      final scope = Scope();
      expect(() => scope.read(cycle), throwsA(isA<StateError>()));
      scope.dispose();
    });

    test('indirect cycle throws', () {
      late Store<int> a;
      late Store<int> b;
      a = Store<int>.derive((s) => b(s));
      b = Store<int>.derive((s) => a(s));
      final scope = Scope();
      expect(() => scope.read(a), throwsA(isA<StateError>()));
      scope.dispose();
    });
  });

  // ── G4: Debug labels ──────────────────────────────────────────────────────

  group('Debug labels', () {
    test('Event toString uses debugLabel', () {
      const e = Event<int>(debugLabel: 'add');
      expect(e.toString(), contains('add'));
    });

    test('Store.derive toString uses debugLabel', () {
      final s = Store<int>.derive((_) => 0, debugLabel: 'zero');
      expect(s.toString(), contains('zero'));
    });

    test('Store.accum toString uses debugLabel', () {
      final s = Store<int>.accum((_) => 0, debugLabel: 'counter');
      expect(s.toString(), contains('counter'));
    });

    test('cycle error mentions store debugLabel', () {
      late Store<int> cycle;
      cycle = Store<int>.derive((s) => cycle(s), debugLabel: 'oops');
      final scope = Scope();
      try {
        scope.read(cycle);
        fail('expected StateError');
      } on StateError catch (e) {
        expect(e.message, contains('oops'));
      }
      scope.dispose();
    });
  });

  // ── G5: Disposed-scope guards ─────────────────────────────────────────────

  group('Disposed-scope guards', () {
    test('read on disposed scope throws', () {
      final store = Store<int>.accum((_) => 0);
      final scope = Scope();
      scope.read(store);
      scope.dispose();
      expect(() => scope.read(store), throwsA(isA<StateError>()));
    });

    test('fire on disposed scope throws', () {
      final e = Event<void>();
      final scope = Scope();
      scope.dispose();
      expect(() => e(scope), throwsA(isA<StateError>()));
    });

    test('fork on disposed scope throws', () {
      final scope = Scope();
      scope.dispose();
      expect(() => scope.fork(), throwsA(isA<StateError>()));
    });

    test('listen on disposed scope throws', () {
      final e = Event<void>();
      final scope = Scope();
      scope.dispose();
      expect(() => scope.listen(e, (_) {}), throwsA(isA<StateError>()));
    });

    test('isDisposed flips after dispose', () {
      final scope = Scope();
      expect(scope.isDisposed, false);
      scope.dispose();
      expect(scope.isDisposed, true);
    });
  });

  // ── G6: Custom equality ───────────────────────────────────────────────────

  group('Custom equality', () {
    test('derived store with custom equals skips emit when equal', () async {
      final inc = Event<void>();
      final src = Store<List<int>>.accum((ctx) {
        ctx.on(inc, (_) async* { yield [...ctx.current, ctx.current.length]; });
        return <int>[];
      });
      // length-based equality on the derived view
      final view = Store<int>.derive(
        (s) => src(s).length,
        equals: (a, b) => a == b,
      );
      final scope = Scope();
      final emitted = <int>[];
      scope.stream(view).listen(emitted.add);
      scope.read(view);

      inc(scope);
      await Future.delayed(Duration.zero);
      inc(scope);
      await Future.delayed(Duration.zero);

      expect(emitted, [1, 2]);
      scope.dispose();
    });

    test('accum store with custom equals suppresses no-op updates', () async {
      final setList = Event<List<int>>();
      final store = Store<List<int>>.accum(
        (ctx) {
          ctx.on(setList, (v) async* { yield v; });
          return <int>[];
        },
        equals: (a, b) => a.length == b.length,
      );
      final scope = Scope();
      final emitted = <List<int>>[];
      scope.stream(store).listen(emitted.add);
      scope.read(store);

      setList(scope, [1]); // length 0→1: emits
      await Future.delayed(Duration.zero);
      setList(scope, [9]); // length 1→1: suppressed
      await Future.delayed(Duration.zero);
      setList(scope, [9, 9]); // length 1→2: emits
      await Future.delayed(Duration.zero);

      expect(emitted.length, 2);
      scope.dispose();
    });
  });

  // ── G8: Introspection ────────────────────────────────────────────────────

  group('Scope introspection', () {
    test('debugBoundStores exposes overrides', () {
      final s = Store<int>.accum((_) => 0);
      final scope = Scope();
      final child = scope.fork(overrides: {s});
      expect(child.debugBoundStores, contains(s));
      expect(scope.debugBoundStores, isNot(contains(s)));
      scope.dispose();
    });

    test('debugBoundEvents exposes event overrides', () {
      final e = Event<void>(debugLabel: 'tick');
      final scope = Scope(overrides: {e});
      expect(scope.debugBoundEvents, contains(e));
      scope.dispose();
    });

    test('debugChildren exposes forks', () {
      final root = Scope();
      final a = root.fork();
      final b = root.fork();
      expect(root.debugChildren, containsAll([a, b]));
      root.dispose();
    });
  });

  // ── G9: scope.listen ─────────────────────────────────────────────────────

  group('scope.listen', () {
    test('handler runs on fire', () {
      final e = Event<int>();
      final scope = Scope();
      final received = <int>[];
      scope.listen(e, received.add);
      e(scope, 1);
      e(scope, 2);
      e(scope, 3);
      expect(received, [1, 2, 3]);
      scope.dispose();
    });

    test('cancelling subscription stops dispatch', () {
      final e = Event<int>();
      final scope = Scope();
      final received = <int>[];
      final sub = scope.listen(e, received.add);
      e(scope, 1);
      sub.cancel();
      e(scope, 2);
      expect(received, [1]);
      scope.dispose();
    });

    test('listener reaches descendants via broadcast', () {
      final e = Event<void>();
      final root = Scope(overrides: {e});
      final child = root.fork();
      var hits = 0;
      child.listen(e, (_) => hits++);
      e(root); // broadcast through subtree
      expect(hits, 1);
      root.dispose();
    });
  });

  // ── G10: Store.select ────────────────────────────────────────────────────

  group('Store.select', () {
    test('select projects a slice', () async {
      final inc = Event<void>();
      final user = Store<({String name, int age})>.accum((ctx) {
        ctx.on(inc, (_) async* {
          yield (name: ctx.current.name, age: ctx.current.age + 1);
        });
        return (name: 'Alice', age: 30);
      });
      final age = user.select((u) => u.age);
      final scope = Scope();
      expect(scope.read(age), 30);
      inc(scope);
      await Future.delayed(Duration.zero);
      expect(scope.read(age), 31);
      scope.dispose();
    });
  });

  // ── T2: Concurrency strategies ───────────────────────────────────────────

  group('Concurrency', () {
    test('parallel (default) interleaves invocations', () async {
      final go = Event<int>();
      final store = Store<List<int>>.accum((ctx) {
        ctx.on(go, (v) async* {
          await Future.delayed(Duration(milliseconds: 20 - v * 10));
          yield [...ctx.current, v];
        });
        return <int>[];
      });
      final scope = Scope();
      scope.read(store);
      go(scope, 0); // delays 20ms
      go(scope, 1); // delays 10ms — completes first
      await Future.delayed(const Duration(milliseconds: 50));
      // Parallel: both ran concurrently; the 10ms one yielded before the 20ms one.
      expect(scope.read(store), [1, 0]);
      scope.dispose();
    });

    test('drop ignores subsequent fires while one is in flight', () async {
      final go = Event<int>();
      var calls = 0;
      final store = Store<int>.accum((ctx) {
        ctx.on(
          go,
          (v) async* {
            calls++;
            await Future.delayed(const Duration(milliseconds: 20));
            yield v;
          },
          concurrency: Concurrency.drop,
        );
        return 0;
      });
      final scope = Scope();
      scope.read(store);
      go(scope, 1);
      go(scope, 2); // dropped
      go(scope, 3); // dropped
      await Future.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      expect(scope.read(store), 1);
      scope.dispose();
    });

    test('restart cancels previous yields and runs latest', () async {
      final go = Event<int>();
      final store = Store<int>.accum((ctx) {
        ctx.on(
          go,
          (v) async* {
            await Future.delayed(const Duration(milliseconds: 20));
            yield v;
          },
          concurrency: Concurrency.restart,
        );
        return 0;
      });
      final scope = Scope();
      scope.read(store);
      final stateSeq = <int>[];
      scope.stream(store).listen(stateSeq.add);

      go(scope, 1);
      await Future.delayed(const Duration(milliseconds: 5));
      go(scope, 2); // cancels 1's pending yield
      await Future.delayed(const Duration(milliseconds: 50));

      // The cancelled handler's `yield 1` never reaches the store.
      expect(stateSeq, [2]);
      expect(scope.read(store), 2);
      scope.dispose();
    });

    test('queue serializes invocations in arrival order', () async {
      final go = Event<int>();
      final yields = <int>[];
      final store = Store<int>.accum((ctx) {
        ctx.on(
          go,
          (v) async* {
            await Future.delayed(const Duration(milliseconds: 10));
            yields.add(v);
            yield v;
          },
          concurrency: Concurrency.queue,
        );
        return 0;
      });
      final scope = Scope();
      scope.read(store);
      go(scope, 1);
      go(scope, 2);
      go(scope, 3);
      await Future.delayed(const Duration(milliseconds: 80));
      expect(yields, [1, 2, 3]); // serialized in arrival order
      expect(scope.read(store), 3);
      scope.dispose();
    });
  });
}
