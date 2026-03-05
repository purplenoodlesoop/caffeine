import 'dart:async';

import 'package:caffeine/caffeine.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

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

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── 1. Store: read / fire ─────────────────────────────────────────────────

  group('Store — read and fire', () {
    late Scope scope;
    late Store<CounterState, CounterEvent> counter;

    setUp(() {
      scope = Scope();
      counter = makeCounter();
    });
    tearDown(() => scope.dispose());

    test('initial state is readable', () {
      expect(scope.read(counter).count, 0);
    });

    test('fire increments state', () {
      scope.fire(counter(CounterEvent.increment));
      expect(scope.read(counter).count, 1);
    });

    test('fire decrement', () {
      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.decrement));
      expect(scope.read(counter).count, 1);
    });

    test('fire reset', () {
      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.reset));
      expect(scope.read(counter).count, 0);
    });

    test('multiple fires accumulate', () {
      for (var i = 0; i < 5; i++) {
        scope.fire(counter(CounterEvent.increment));
      }
      expect(scope.read(counter).count, 5);
    });

    test('equal new state does not trigger notification', () async {
      // reset when already 0 — no change
      final states = <int>[];
      scope.stream(counter).listen((s) => states.add(s.count));
      scope.fire(counter(CounterEvent.reset));
      await Future.microtask(() {});
      expect(states, isEmpty);
    });
  });

  // ── 2. Scope.stream ───────────────────────────────────────────────────────

  group('Scope.stream', () {
    late Scope scope;
    late Store<CounterState, CounterEvent> counter;

    setUp(() {
      scope = Scope();
      counter = makeCounter();
    });
    tearDown(() => scope.dispose());

    test('emits on each state change', () async {
      final states = <int>[];
      scope.stream(counter).listen((s) => states.add(s.count));

      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));

      await Future.microtask(() {});
      expect(states, [1, 2, 3]);
    });

    test('multiple independent listeners both receive events', () async {
      final a = <int>[];
      final b = <int>[];
      scope.stream(counter).listen((s) => a.add(s.count));
      scope.stream(counter).listen((s) => b.add(s.count));

      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));

      await Future.microtask(() {});
      expect(a, [1, 2]);
      expect(b, [1, 2]);
    });
  });

  // ── 3. Effects ────────────────────────────────────────────────────────────

  group('Effects', () {
    test('async effect dispatches follow-on event', () async {
      final store = Store<List<String>, String>(
        (self) => (
          () => (<String>[], Stream.empty),
          (event, state) => switch (event) {
            'start' => (
                state,
                () async* {
                  await Future.delayed(Duration.zero);
                  yield self('done');
                },
              ),
            'done' => ([...state, 'done'], Stream.empty),
            _ => (state, Stream.empty),
          },
        ),
      );

      final scope = Scope();
      scope.fire(store('start'));
      await Future.delayed(const Duration(milliseconds: 10));
      expect(scope.read(store), ['done']);
      scope.dispose();
    });

    test('initial effect fires on store init', () async {
      final store = Store<int, String>(
        (self) => (
          () => (0, () async* { yield self('init'); }),
          (event, state) => switch (event) {
            'init' => (state + 1, Stream.empty),
            _ => (state, Stream.empty),
          },
        ),
      );

      final scope = Scope();
      scope.read(store);
      await Future.microtask(() {});
      expect(scope.read(store), 1);
      scope.dispose();
    });

    test('effect yields multiple events in order', () async {
      final store = Store<int, int>(
        (self) => (
          () => (0, Stream.empty),
          (event, state) => (
            state + event,
            event == 10
                ? () async* {
                    yield self(1);
                    yield self(2);
                    yield self(3);
                  }
                : Stream.empty,
          ),
        ),
      );

      final scope = Scope();
      scope.fire(store(10));
      await Future.delayed(const Duration(milliseconds: 10));
      // 10 + 1 + 2 + 3 = 16
      expect(scope.read(store), 16);
      scope.dispose();
    });

    test('self-dispatching store drives multi-step workflow', () async {
      // Uses the `self` EventConsumer to chain events inside a single store
      final store = Store<String, String>(
        (self) => (
          () => ('idle', Stream.empty),
          (event, state) => switch (event) {
            'start' => ('loading', () async* {
                await Future.delayed(Duration.zero);
                yield self('loaded');
              }),
            'loaded' => ('done', Stream.empty),
            _ => (state, Stream.empty),
          },
        ),
      );

      final scope = Scope();
      scope.fire(store('start'));
      expect(scope.read(store), 'loading');
      await Future.delayed(const Duration(milliseconds: 10));
      expect(scope.read(store), 'done');
      scope.dispose();
    });
  });

  // ── 4. Cross-store dispatch ───────────────────────────────────────────────

  group('Cross-store dispatch', () {
    test('store effect targets another store', () async {
      final log = Store<List<String>, String>(
        (self) => (
          () => (<String>[], Stream.empty),
          (event, state) => ([...state, event], Stream.empty),
        ),
      );

      final producer = Store<int, String>(
        (self) => (
          () => (0, Stream.empty),
          (event, state) => switch (event) {
            'go' => (state + 1, () async* { yield log('produced'); }),
            _ => (state, Stream.empty),
          },
        ),
      );

      final scope = Scope();
      scope.fire(producer('go'));
      await Future.microtask(() {});
      expect(scope.read(log), ['produced']);
      scope.dispose();
    });
  });

  // ── 5. Stateful ───────────────────────────────────────────────────────────

  group('Stateful', () {
    late Scope scope;
    late Store<CounterState, CounterEvent> counter;

    setUp(() {
      scope = Scope();
      counter = makeCounter();
    });
    tearDown(() => scope.dispose());

    test('reads derived value', () {
      final doubled = Stateful(($) => $(counter).count * 2);
      expect(scope.read(doubled), 0);
    });

    test('recomputes when dependency changes', () {
      final doubled = Stateful(($) => $(counter).count * 2);
      scope.read(doubled);
      scope.fire(counter(CounterEvent.increment));
      expect(scope.read(doubled), 2);
    });

    test('chains Stateful nodes', () {
      final doubled = Stateful(($) => $(counter).count * 2);
      final quadrupled = Stateful(($) => $(doubled) * 2);
      scope.fire(counter(CounterEvent.increment));
      expect(scope.read(quadrupled), 4);
    });

    test('stream emits when Stateful changes', () async {
      final doubled = Stateful(($) => $(counter).count * 2);
      final emitted = <int>[];
      scope.stream(doubled).listen(emitted.add);

      scope.fire(counter(CounterEvent.increment));
      scope.fire(counter(CounterEvent.increment));

      await Future.microtask(() {});
      expect(emitted, [2, 4]);
    });

    test('does not recompute when store state is unchanged', () {
      var computeCount = 0;
      final derived = Stateful(($) {
        computeCount++;
        return $(counter).count;
      });

      scope.read(derived);
      computeCount = 0;

      scope.fire(counter(CounterEvent.reset)); // already 0, no change
      scope.fire(counter(CounterEvent.reset));
      scope.read(derived);

      expect(computeCount, 0);
    });

    test('does not emit when recomputed value is same as before', () async {
      // isPositive stays true when counter goes 1 → 2
      final isPositive = Stateful(($) => $(counter).count > 0);
      final emitted = <bool>[];
      scope.stream(isPositive).listen(emitted.add);

      scope.fire(counter(CounterEvent.increment)); // 0→1: false→true, emits
      scope.fire(counter(CounterEvent.increment)); // 1→2: true→true, no emit

      await Future.microtask(() {});
      expect(emitted, [true]); // only one emission
    });
  });

  // ── 6. Diamond — update compression ──────────────────────────────────────

  group('Diamond — update compression', () {
    test('leaf recomputes exactly once when two deps change together', () {
      final user = Store<UserState, UserState>(
        (self) => (
          () => ((firstName: 'John', lastName: 'Doe'), Stream.empty),
          (event, state) => (event, Stream.empty),
        ),
      );

      final upper1 = Stateful(($) => $(user).firstName.toUpperCase());
      final upper2 = Stateful(($) => $(user).lastName.toUpperCase());

      var recomputeCount = 0;
      final combined = Stateful(($) {
        recomputeCount++;
        return '${$(upper1)} ${$(upper2)}';
      });

      final scope = Scope();
      scope.read(combined);
      recomputeCount = 0;

      scope.fire(user((firstName: 'Jane', lastName: 'Smith')));

      expect(scope.read(combined), 'JANE SMITH');
      expect(recomputeCount, 1);
      scope.dispose();
    });

    test('leaf does not emit when both deps recompute to same value', () async {
      // absName = |firstName| + |lastName|, both flip sign but abs stays same
      final user = Store<UserState, UserState>(
        (self) => (
          () => ((firstName: 'A', lastName: 'B'), Stream.empty),
          (event, state) => (event, Stream.empty),
        ),
      );

      final len1 = Stateful<int>(($) => $(user).firstName.length);
      final len2 = Stateful<int>(($) => $(user).lastName.length);
      final total = Stateful<int>(($) => $(len1) + $(len2));

      final emitted = <int>[];
      final scope = Scope();
      scope.stream(total).listen(emitted.add);
      scope.read(total); // warm up

      // 'A'(1)+'B'(1)=2 → 'XX'(2)+'YY'(2)=4: changes
      scope.fire(user((firstName: 'XX', lastName: 'YY')));
      // 'XX'(2)+'YY'(2)=4 → 'AB'(2)+'CD'(2)=4: total stays 4, no emit
      scope.fire(user((firstName: 'AB', lastName: 'CD')));

      await Future.microtask(() {});
      expect(emitted, [4]); // only one emission
      scope.dispose();
    });
  });

  // ── 7. External subscribe ─────────────────────────────────────────────────

  group('External subscribe', () {
    test('external stream events are dispatched to store', () async {
      final controller = StreamController<int>();

      final store = Store<int, int>(
        subscribe: (_) => controller.stream,
        (self) => (
          () => (0, Stream.empty),
          (event, state) => (state + event, Stream.empty),
        ),
      );

      final scope = Scope();
      scope.read(store);

      controller.add(5);
      controller.add(3);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(scope.read(store), 8);
      await controller.close();
      scope.dispose();
    });

    test('external subscription is cancelled on dispose', () async {
      var dispatchCount = 0;
      final controller = StreamController<int>.broadcast();

      final store = Store<int, int>(
        subscribe: (_) => controller.stream,
        (self) => (
          () => (0, Stream.empty),
          (event, state) {
            dispatchCount++;
            return (state + event, Stream.empty);
          },
        ),
      );

      final scope = Scope();
      scope.read(store);
      await Future.delayed(Duration.zero);

      scope.dispose(); // cancels subscription

      controller.add(99); // should not reach the store
      await Future.delayed(const Duration(milliseconds: 10));

      expect(dispatchCount, 0);
      await controller.close();
    });
  });

  // ── 8. Scope fork & lifecycle ─────────────────────────────────────────────

  group('Scope fork', () {
    test('child reads store initialized in parent', () {
      final counter = makeCounter();
      final root = Scope();
      root.fire(counter(CounterEvent.increment));

      final child = root.fork();
      expect(child.read(counter).count, 1);
      root.dispose();
    });

    test('unbound store goes to root even when first accessed via child', () {
      final counter = makeCounter();
      final root = Scope();
      final child = root.fork();

      // First access is from child — but counter is unbound, so root owns it
      child.fire(counter(CounterEvent.increment));
      expect(root.read(counter).count, 1); // root sees it

      child.dispose();
      // After child disposes, root still has the store
      expect(root.read(counter).count, 1);
      root.dispose();
    });

    test('bound store is local to child scope', () {
      final root = Scope();
      final counter = makeCounter();
      final child = root.fork(references: {counter});

      child.fire(counter(CounterEvent.increment));
      expect(child.read(counter).count, 1);

      child.dispose();
      root.dispose();
    });

    test('disposing child cleans up its bound store stream', () async {
      final root = Scope();
      final counter = makeCounter();
      final child = root.fork(references: {counter});

      final received = <CounterState>[];
      child.stream(counter).listen(received.add);

      child.fire(counter(CounterEvent.increment)); // emits (count: 1)
      await Future.microtask(() {});
      expect(received, [(count: 1)]);

      child.dispose(); // closes stream controller

      expect(received, [(count: 1)]); // no further emissions
      root.dispose();
    });

    test('disposing child does not affect parent stores', () {
      final sharedCounter = makeCounter();
      final root = Scope();
      root.read(sharedCounter);
      root.fire(sharedCounter(CounterEvent.increment));

      final child = root.fork();
      child.dispose();

      expect(root.read(sharedCounter).count, 1);
      root.dispose();
    });

    test('nested fork: disposing grandchild does not affect parent or root', () {
      final rootCounter = makeCounter();
      final childCounter = makeCounter();
      final grandCounter = makeCounter();

      final root = Scope();
      final child = root.fork(references: {childCounter});
      final grand = child.fork(references: {grandCounter});

      root.fire(rootCounter(CounterEvent.increment));
      child.fire(childCounter(CounterEvent.increment));
      grand.fire(grandCounter(CounterEvent.increment));

      grand.dispose(); // cleans up grandCounter only

      expect(root.read(rootCounter).count, 1);
      expect(child.read(childCounter).count, 1);
      root.dispose();
    });

    test('StoreOverride in forked scope is local — parent sees original', () {
      final real = makeCounter();
      final fake = makeCounter();

      final root = Scope();
      root.fire(real(CounterEvent.increment)); // root: real=1

      final child = root.fork(references: {StoreOverride(real, fake)});
      child.fire(real(CounterEvent.increment)); // child: fires into fake
      child.fire(real(CounterEvent.increment));

      expect(child.read(real).count, 2); // child sees fake
      expect(root.read(real).count, 1); // root still sees real

      child.dispose();
      root.dispose();
    });
  });

  // ── 9. StoreOverride ─────────────────────────────────────────────────────

  group('StoreOverride', () {
    test('root scope override replaces store transparently', () {
      final real = makeCounter();
      final fake = makeCounter();

      final scope = Scope(references: {StoreOverride(real, fake)});
      scope.fire(real(CounterEvent.increment));
      scope.fire(real(CounterEvent.increment));

      expect(scope.read(real).count, 2);
      expect(scope.read(fake).count, 2);
      scope.dispose();
    });
  });

  // ── 10. Snapshot.current ─────────────────────────────────────────────────

  group('Snapshot.current', () {
    test('reads last value without registering dependency', () {
      final counter = makeCounter();
      final scope = Scope();
      scope.read(counter);

      var recomputeCount = 0;
      final toggle = Store<bool, bool>(
        (self) => (
          () => (false, Stream.empty),
          (event, state) => (event, Stream.empty),
        ),
      );

      final derived = Stateful<int>(($) {
        $(toggle); // real dependency
        recomputeCount++;
        return $.current ?? 0; // reads counter without registering dep
      });

      scope.read(derived);
      recomputeCount = 0;

      // counter changes — derived must NOT recompute
      scope.fire(counter(CounterEvent.increment));
      scope.read(derived);
      expect(recomputeCount, 0);

      // toggle changes — derived MUST recompute
      scope.fire(toggle(true));
      scope.read(derived);
      expect(recomputeCount, 1);

      scope.dispose();
    });
  });
}
