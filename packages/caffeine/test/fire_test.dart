import 'dart:async';

import 'package:caffeine/caffeine.dart';
import 'package:test/test.dart';

void main() {
  // ── Awaiting fire ─────────────────────────────────────────────────────────

  group('await fire', () {
    test('state is settled when the future completes', () async {
      final inc = Event<void>();
      final counter = Store<int>.accum((ctx) {
        ctx.on(inc, (_) async* {
          yield ctx.current + 1;
        });
        return 0;
      });
      final doubled = Store<int>.derive((s) => counter(s) * 2);
      final scope = Scope();
      scope.read(doubled); // stores register handlers on first read

      await inc(scope);
      expect(scope.read(counter), 1);
      expect(scope.read(doubled), 2);
      scope.dispose();
    });

    test('waits for async work between yields', () async {
      final load = Event<int>();
      final store = Store<String>.accum((ctx) {
        ctx.on(load, (id) async* {
          yield 'loading';
          await Future<void>.delayed(const Duration(milliseconds: 10));
          yield 'user $id';
        });
        return 'idle';
      });
      final scope = Scope();
      scope.read(store);

      await load(scope, 7);
      expect(scope.read(store), 'user 7');
      scope.dispose();
    });

    test('stream listeners are notified before the future completes', () async {
      final inc = Event<void>();
      final counter = Store<int>.accum((ctx) {
        ctx.on(inc, (_) async* {
          yield ctx.current + 1;
        });
        return 0;
      });
      final doubled = counter.select((c) => c * 2);
      final scope = Scope();
      final seen = <int>[];
      scope.stream(doubled).listen(seen.add);

      await inc(scope);
      expect(seen, [2]);
      scope.dispose();
    });

    test('completes when every handler in the broadcast has finished', () async {
      final go = Event<void>();
      final log = <String>[];
      Store<int> slow(String name, int ms) => Store<int>.accum((ctx) {
            ctx.on(go, (_) async* {
              await Future<void>.delayed(Duration(milliseconds: ms));
              log.add(name);
              yield 1;
            });
            return 0;
          });
      final a = slow('a', 5);
      final b = slow('b', 15);
      final root = Scope();
      final left = root.fork(overrides: {a});
      final right = root.fork(overrides: {b});
      left.read(a);
      right.read(b);

      await go(left); // unbound: broadcasts from root into both forks
      expect(log, unorderedEquals(['a', 'b']));
      root.dispose();
    });

    test('a follow-up fire is included only when awaited', () async {
      final outer = Event<void>();
      final inner = Event<void>();
      final target = Store<int>.accum((ctx) {
        ctx.on(inner, (_) async* {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          yield ctx.current + 1;
        });
        return 0;
      });
      final awaiting = Store<void>.accum((ctx) {
        ctx.on(outer, (_) async* {
          await inner(ctx);
        });
      });
      final scope = Scope();
      scope.read(target);
      scope.read(awaiting);

      await outer(scope);
      expect(scope.read(target), 1);
      scope.dispose();
    });

    test('completes immediately when no handler listens', () async {
      final nobody = Event<int>();
      final scope = Scope();
      await nobody(scope, 1);
      scope.dispose();
    });
  });

  // ── Concurrency and the returned future ───────────────────────────────────

  group('await fire with concurrency', () {
    Store<List<int>> store(Event<int> event, Concurrency concurrency) =>
        Store<List<int>>.accum((ctx) {
          ctx.on(event, (n) async* {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            yield [...ctx.current, n];
          }, concurrency: concurrency);
          return const [];
        });

    test('drop: a dropped fire completes without waiting', () async {
      final e = Event<int>();
      final s = store(e, Concurrency.drop);
      final scope = Scope();
      scope.read(s);

      final first = e(scope, 1);
      await e(scope, 2); // dropped
      expect(scope.read(s), isEmpty);
      await first;
      expect(scope.read(s), [1]);
      scope.dispose();
    });

    test('restart: the replaced fire completes when cancelled', () async {
      final e = Event<int>();
      final s = store(e, Concurrency.restart);
      final scope = Scope();
      scope.read(s);

      final first = e(scope, 1);
      final second = e(scope, 2);
      await first;
      await second;
      expect(scope.read(s), [2]);
      scope.dispose();
    });

    test('queue: each fire completes after its own turn', () async {
      final e = Event<int>();
      final s = store(e, Concurrency.queue);
      final scope = Scope();
      scope.read(s);

      final first = e(scope, 1);
      final second = e(scope, 2);
      await first;
      expect(scope.read(s), [1]);
      await second;
      expect(scope.read(s), [1, 2]);
      scope.dispose();
    });

    test('dispose completes in-flight and queued fires', () async {
      final e = Event<int>();
      final s = store(e, Concurrency.queue);
      final scope = Scope();
      scope.read(s);

      final running = e(scope, 1);
      final queued = e(scope, 2);
      scope.dispose();
      await Future.wait([running, queued])
          .timeout(const Duration(milliseconds: 100));
    });
  });

  // ── Consistency before settling ───────────────────────────────────────────

  group('reads between yields', () {
    test('derived stores never lag behind their sources', () async {
      final inc = Event<void>();
      final counter = Store<int>.accum((ctx) {
        ctx.on(inc, (_) async* {
          yield ctx.current + 1;
          yield ctx.current + 1;
        });
        return 0;
      });
      final doubled = Store<int>.derive((s) => counter(s) * 2);
      final scope = Scope();
      scope.read(doubled);

      final settled = inc(scope);
      for (var i = 0; i < 4; i++) {
        expect(scope.read(doubled), scope.read(counter) * 2);
        await Future<void>.microtask(() {});
      }
      await settled;
      expect(scope.read(doubled), 4);
      scope.dispose();
    });

    test('a stream emits nothing when the value reverts within a batch',
        () async {
      final flip = Event<void>();
      final store = Store<int>.accum((ctx) {
        ctx.on(flip, (_) async* {
          yield 1;
        });
        ctx.on(flip, (_) async* {
          yield 0;
        });
        return 0;
      });
      final scope = Scope();
      final seen = <int>[];
      scope.stream(store).listen(seen.add);

      await flip(scope);
      expect(seen, isEmpty);
      scope.dispose();
    });
  });
}
