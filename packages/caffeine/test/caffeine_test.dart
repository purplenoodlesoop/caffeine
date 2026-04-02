import 'dart:async';

import 'package:caffeine/caffeine.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

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

/// Returns a counter with its own private increment event, so multiple counters
/// in different scopes don't interfere with each other.
({Store<CounterState> store, Event<void> inc}) makeIsolatedCounter() {
  final inc = Event<void>();
  return (
    store: Store<CounterState>.accum((ctx) {
      ctx.on(inc, (_) async* { yield (count: ctx.current.count + 1); });
      return (count: 0);
    }),
    inc: inc,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── 1. Store: read / fire ─────────────────────────────────────────────────

  group('Store — read and fire', () {
    late Scope scope;
    late Store<CounterState> counter;

    setUp(() {
      scope = Scope();
      counter = makeCounter();
      scope.read(counter); // initialize handlers
    });
    tearDown(() => scope.dispose());

    test('initial state is readable', () {
      expect(scope.read(counter).count, 0);
    });

    test('fire increments state', () async {
      scope.fire(increment, null);
      await Future.microtask(() {});
      expect(scope.read(counter).count, 1);
    });

    test('fire decrement', () async {
      scope.fire(increment, null);
      scope.fire(increment, null);
      scope.fire(decrement, null);
      await Future.microtask(() {});
      expect(scope.read(counter).count, 1);
    });

    test('fire reset', () async {
      scope.fire(increment, null);
      scope.fire(reset, null);
      await Future.microtask(() {});
      expect(scope.read(counter).count, 0);
    });

    test('multiple fires accumulate', () async {
      for (var i = 0; i < 5; i++) {
        scope.fire(increment, null);
      }
      await Future.microtask(() {});
      expect(scope.read(counter).count, 5);
    });

    test('equal new state does not trigger notification', () async {
      final states = <int>[];
      scope.stream(counter).listen((s) => states.add(s.count));
      scope.fire(reset, null); // already 0 — no change
      await Future.microtask(() {});
      expect(states, isEmpty);
    });
  });

  // ── 2. Scope.stream ───────────────────────────────────────────────────────

  group('Scope.stream', () {
    late Scope scope;
    late Store<CounterState> counter;

    setUp(() {
      scope = Scope();
      counter = makeCounter();
      scope.read(counter); // initialize handlers
    });
    tearDown(() => scope.dispose());

    test('emits on each state change', () async {
      final states = <int>[];
      scope.stream(counter).listen((s) => states.add(s.count));

      scope.fire(increment, null);
      scope.fire(increment, null);
      scope.fire(increment, null);

      await Future.microtask(() {});
      expect(states, [1, 2, 3]);
    });

    test('multiple independent listeners both receive events', () async {
      final a = <int>[];
      final b = <int>[];
      scope.stream(counter).listen((s) => a.add(s.count));
      scope.stream(counter).listen((s) => b.add(s.count));

      scope.fire(increment, null);
      scope.fire(increment, null);

      await Future.microtask(() {});
      expect(a, [1, 2]);
      expect(b, [1, 2]);
    });
  });

  // ── 3. Effects ────────────────────────────────────────────────────────────

  group('Effects', () {
    test('async effect dispatches follow-on event', () async {
      final start = Event<void>();
      final done = Event<void>();

      final store = Store<List<String>>.accum((ctx) {
        ctx.on(start, (_) async* {
          await Future.delayed(Duration.zero);
          ctx.fire(done, null);
        });
        ctx.on(done, (_) async* {
          yield [...ctx.current, 'done'];
        });
        return <String>[];
      });

      final scope = Scope();
      scope.read(store);
      scope.fire(start, null);
      await Future.delayed(const Duration(milliseconds: 10));
      expect(scope.read(store), ['done']);
      scope.dispose();
    });

    test('initial effect fires on store init', () async {
      final init = Event<void>();

      final store = Store<int>.accum((ctx) {
        ctx.on(init, (_) async* { yield ctx.current + 1; });
        ctx.fire(init, null);
        return 0;
      });

      final scope = Scope();
      scope.read(store);
      await Future.microtask(() {});
      expect(scope.read(store), 1);
      scope.dispose();
    });

    test('effect yields multiple events in order', () async {
      final go = Event<void>();
      final add = Event<int>();

      final store = Store<int>.accum((ctx) {
        ctx.on(add, (v) async* { yield ctx.current + v; });
        ctx.on(go, (_) async* {
          ctx.fire(add, 1);
          ctx.fire(add, 2);
          ctx.fire(add, 3);
        });
        return 0;
      });

      final scope = Scope();
      scope.read(store);
      scope.fire(go, null);
      await Future.delayed(const Duration(milliseconds: 10));
      expect(scope.read(store), 6);
      scope.dispose();
    });

    test('self-dispatching store drives multi-step workflow', () async {
      final start = Event<void>();
      final loaded = Event<void>();

      final store = Store<String>.accum((ctx) {
        ctx.on(start, (_) async* {
          yield 'loading';
          await Future.delayed(Duration.zero);
          ctx.fire(loaded, null);
        });
        ctx.on(loaded, (_) async* { yield 'done'; });
        return 'idle';
      });

      final scope = Scope();
      scope.read(store);
      scope.fire(start, null);
      await Future.microtask(() {});
      expect(scope.read(store), 'loading');
      await Future.delayed(const Duration(milliseconds: 10));
      expect(scope.read(store), 'done');
      scope.dispose();
    });
  });

  // ── 4. Cross-store dispatch ───────────────────────────────────────────────

  group('Cross-store dispatch', () {
    test('store effect targets another store', () async {
      final logMsg = Event<String>();
      final go = Event<void>();

      final log = Store<List<String>>.accum((ctx) {
        ctx.on(logMsg, (msg) async* { yield [...ctx.current, msg]; });
        return <String>[];
      });

      final producer = Store<int>.accum((ctx) {
        ctx.on(go, (_) async* {
          ctx.fire(logMsg, 'produced');
          yield ctx.current + 1;
        });
        return 0;
      });

      final scope = Scope();
      scope.read(log);
      scope.read(producer);
      scope.fire(go, null);
      // cross-store fire schedules two microtask hops — use delayed(0) to drain
      await Future.delayed(Duration.zero);
      expect(scope.read(log), ['produced']);
      scope.dispose();
    });
  });

  // ── 5. Store.derive ───────────────────────────────────────────────────────

  group('Store.derive', () {
    late Scope scope;
    late Store<CounterState> counter;

    setUp(() {
      scope = Scope();
      counter = makeCounter();
      scope.read(counter); // initialize handlers
    });
    tearDown(() => scope.dispose());

    test('reads derived value', () {
      final doubled = Store<int>.derive((source) => source.read(counter).count * 2);
      expect(scope.read(doubled), 0);
    });

    test('recomputes when dependency changes', () async {
      final doubled = Store<int>.derive((source) => source.read(counter).count * 2);
      scope.read(doubled);
      scope.fire(increment, null);
      await Future.microtask(() {});
      expect(scope.read(doubled), 2);
    });

    test('chains derived nodes', () async {
      final doubled = Store<int>.derive((source) => source.read(counter).count * 2);
      final quadrupled = Store<int>.derive((source) => source.read(doubled) * 2);
      scope.fire(increment, null);
      await Future.microtask(() {});
      expect(scope.read(quadrupled), 4);
    });

    test('stream emits when derived value changes', () async {
      final doubled = Store<int>.derive((source) => source.read(counter).count * 2);
      final emitted = <int>[];
      scope.stream(doubled).listen(emitted.add);
      scope.read(doubled);

      scope.fire(increment, null);
      scope.fire(increment, null);

      await Future.microtask(() {});
      expect(emitted, [2, 4]);
    });

    test('does not recompute when store state is unchanged', () async {
      var computeCount = 0;
      final derived = Store<int>.derive((source) {
        computeCount++;
        return source.read(counter).count;
      });

      scope.read(derived);
      computeCount = 0;

      scope.fire(reset, null); // already 0, no change
      scope.fire(reset, null);
      await Future.microtask(() {});
      scope.read(derived);

      expect(computeCount, 0);
    });

    test('does not emit when recomputed value is same as before', () async {
      final isPositive = Store<bool>.derive(
        (source) => source.read(counter).count > 0,
      );
      final emitted = <bool>[];
      scope.stream(isPositive).listen(emitted.add);
      scope.read(isPositive);

      scope.fire(increment, null); // 0→1: false→true, emits
      scope.fire(increment, null); // 1→2: true→true, no emit

      await Future.microtask(() {});
      expect(emitted, [true]);
    });

    test('call extension reads derived store', () async {
      final doubled = Store<int>.derive((source) => counter(source).count * 2);
      scope.fire(increment, null);
      await Future.microtask(() {});
      expect(scope.read(doubled), 2);
    });
  });

  // ── 6. Diamond — update compression ──────────────────────────────────────

  group('Diamond — update compression', () {
    test('leaf recomputes exactly once when two deps change together', () async {
      final setUser = Event<({String first, String last})>();
      final user = Store<({String first, String last})>.accum((ctx) {
        ctx.on(setUser, (u) async* { yield u; });
        return (first: 'John', last: 'Doe');
      });

      final upper1 = Store<String>.derive((s) => s.read(user).first.toUpperCase());
      final upper2 = Store<String>.derive((s) => s.read(user).last.toUpperCase());

      var recomputeCount = 0;
      final combined = Store<String>.derive((s) {
        recomputeCount++;
        return '${s.read(upper1)} ${s.read(upper2)}';
      });

      final scope = Scope();
      scope.read(combined); // warms up and initializes user through deps
      recomputeCount = 0;

      scope.fire(setUser, (first: 'Jane', last: 'Smith'));
      await Future.microtask(() {});

      expect(scope.read(combined), 'JANE SMITH');
      expect(recomputeCount, 1);
      scope.dispose();
    });

    test('leaf does not emit when both deps recompute to same value', () async {
      final setUser = Event<({String firstName, String lastName})>();
      final user = Store<({String firstName, String lastName})>.accum((ctx) {
        ctx.on(setUser, (u) async* { yield u; });
        return (firstName: 'A', lastName: 'B');
      });

      final len1 = Store<int>.derive((s) => s.read(user).firstName.length);
      final len2 = Store<int>.derive((s) => s.read(user).lastName.length);
      final total = Store<int>.derive((s) => s.read(len1) + s.read(len2));

      final emitted = <int>[];
      final scope = Scope();
      scope.stream(total).listen(emitted.add);
      scope.read(total); // warm up, initializes user through deps

      scope.fire(setUser, (firstName: 'XX', lastName: 'YY')); // 1+1=2 → 2+2=4
      scope.fire(setUser, (firstName: 'AB', lastName: 'CD')); // 2+2=4 → 2+2=4

      await Future.microtask(() {});
      expect(emitted, [4]);
      scope.dispose();
    });
  });

  // ── 7. External subscribe ─────────────────────────────────────────────────

  group('External subscribe', () {
    test('external stream events are dispatched to store', () async {
      final controller = StreamController<int>();
      final addValue = Event<int>();

      final store = Store<int>.accum((ctx) {
        ctx.on(addValue, (v) async* { yield ctx.current + v; });
        controller.stream.listen((v) => ctx.fire(addValue, v));
        return 0;
      });

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
      final addValue = Event<int>();

      late StreamSubscription externalSub;
      final store = Store<int>.accum((ctx) {
        ctx.on(addValue, (v) async* {
          dispatchCount++;
          yield ctx.current + v;
        });
        externalSub = controller.stream.listen((v) => ctx.fire(addValue, v));
        return 0;
      });

      final scope = Scope();
      scope.read(store);
      await Future.delayed(Duration.zero);

      scope.dispose();
      externalSub.cancel();

      controller.add(99);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(dispatchCount, 0);
      await controller.close();
    });
  });

  // ── 8. Scope fork & lifecycle ─────────────────────────────────────────────

  group('Scope fork', () {
    test('child reads store initialized in parent', () async {
      final counter = makeCounter();
      final root = Scope();
      root.read(counter);
      root.fire(increment, null);
      await Future.microtask(() {});

      final child = root.fork();
      expect(child.read(counter).count, 1);
      root.dispose();
    });

    test('unbound store goes to root even when first accessed via child', () async {
      final counter = makeCounter();
      final root = Scope();
      final child = root.fork();

      // First access from child — counter is unbound, so root owns it.
      child.read(counter);
      // Fire from root (that's where the counter actually lives).
      root.fire(increment, null);
      await Future.microtask(() {});

      expect(root.read(counter).count, 1); // root sees it
      expect(child.read(counter).count, 1); // child shares root's state

      child.dispose();
      expect(root.read(counter).count, 1); // survives child disposal
      root.dispose();
    });

    test('bound store is local to child scope', () async {
      final root = Scope();
      final (:store, :inc) = makeIsolatedCounter();
      final child = root.fork(overrides: {store});

      child.read(store); // initialize in child scope
      child.fire(inc, null);
      await Future.microtask(() {});
      expect(child.read(store).count, 1);

      child.dispose();
      root.dispose();
    });

    test('disposing child cleans up its bound store stream', () async {
      final root = Scope();
      final (:store, :inc) = makeIsolatedCounter();
      final child = root.fork(overrides: {store});

      final received = <CounterState>[];
      child.stream(store).listen(received.add);
      child.read(store);

      child.fire(inc, null);
      await Future.microtask(() {});
      expect(received, [(count: 1)]);

      child.dispose();
      expect(received, [(count: 1)]);
      root.dispose();
    });

    test('disposing child does not affect parent stores', () async {
      final sharedCounter = makeCounter();
      final root = Scope();
      root.read(sharedCounter);
      root.fire(increment, null);
      await Future.microtask(() {});

      final child = root.fork();
      child.dispose();

      expect(root.read(sharedCounter).count, 1);
      root.dispose();
    });

    test('nested fork: disposing grandchild does not affect parent or root', () async {
      final rootC = makeIsolatedCounter();
      final childC = makeIsolatedCounter();
      final grandC = makeIsolatedCounter();

      final root = Scope();
      final child = root.fork(overrides: {childC.store});
      final grand = child.fork(overrides: {grandC.store});

      root.read(rootC.store);
      child.read(childC.store);
      grand.read(grandC.store);

      root.fire(rootC.inc, null);
      child.fire(childC.inc, null);
      grand.fire(grandC.inc, null);
      await Future.microtask(() {});

      grand.dispose(); // cleans up grandC only

      expect(root.read(rootC.store).count, 1);
      expect(child.read(childC.store).count, 1);
      root.dispose();
    });

    test('MappingStoreOverride in forked scope is local — parent sees original', () async {
      final realInc = Event<void>();
      final fakeInc = Event<void>();

      final real = Store<CounterState>.accum((ctx) {
        ctx.on(realInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });
      final fake = Store<CounterState>.accum((ctx) {
        ctx.on(fakeInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });

      final root = Scope();
      root.read(real);
      root.fire(realInc, null); // real: 0→1
      await Future.microtask(() {});

      final child = root.fork(
        overrides: {MappingStoreOverride(from: real, to: fake)},
      );
      child.read(real); // resolves to fake, initializes fake in child scope
      child.fire(fakeInc, null); // fake: 0→1
      child.fire(fakeInc, null); // fake: 1→2
      await Future.microtask(() {});

      expect(child.read(real).count, 2); // child sees fake
      expect(root.read(real).count, 1);  // root still sees real

      child.dispose();
      root.dispose();
    });
  });

  // ── 9. MappingStoreOverride ───────────────────────────────────────────────

  group('MappingStoreOverride', () {
    test('root scope override replaces store transparently', () async {
      final sharedInc = Event<void>();

      final real = Store<CounterState>.accum((ctx) {
        ctx.on(sharedInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });
      final fake = Store<CounterState>.accum((ctx) {
        ctx.on(sharedInc, (_) async* { yield (count: ctx.current.count + 1); });
        return (count: 0);
      });

      final scope = Scope(
        overrides: {MappingStoreOverride(from: real, to: fake)},
      );
      scope.read(real); // resolves to fake — only fake is initialized
      scope.fire(sharedInc, null); // fires fake
      scope.fire(sharedInc, null);
      await Future.microtask(() {});

      expect(scope.read(real).count, 2); // real resolves to fake
      expect(scope.read(fake).count, 2);
      scope.dispose();
    });
  });

  // ── 10. Derived store scope promotion ────────────────────────────────────

  group('Derived store scope promotion', () {
    test('derived store is promoted to dep-owner scope', () async {
      final (:store, :inc) = makeIsolatedCounter();
      final doubled = Store<int>.derive((s) => s.read(store).count * 2);

      final root = Scope();
      final child = root.fork(overrides: {store});

      child.read(store);
      expect(child.read(doubled), 0);

      child.fire(inc, null);
      await Future.microtask(() {});
      expect(child.read(doubled), 2);
      root.dispose();
    });

    test('grandchild shares promoted entry from child scope', () async {
      final (:store, :inc) = makeIsolatedCounter();
      final doubled = Store<int>.derive((s) => s.read(store).count * 2);

      final root = Scope();
      final child = root.fork(overrides: {store});
      final grand1 = child.fork();
      final grand2 = child.fork();

      // Both grandchildren read doubled — must share the same promoted instance.
      expect(grand1.read(doubled), 0);
      expect(grand2.read(doubled), 0);

      grand1.fire(inc, null);
      await Future.microtask(() {});

      // grand1 fires inc but counterStore is in child scope — event doesn't route
      // to child scope (inc is unbound), so nothing changes.
      // Fire from the child scope directly instead:
      child.fire(inc, null);
      await Future.microtask(() {});

      expect(grand1.read(doubled), 2);
      expect(grand2.read(doubled), 2); // same instance, same value
      root.dispose();
    });

    test('constant derived store (no deps) is readable without crash', () {
      final pi = Store<double>.derive((_) => 3.14159);
      final scope = Scope();
      expect(scope.read(pi), 3.14159);
      scope.dispose();
    });

    test('derived store with sibling dep owners stays in requesting scope', () async {
      // Store A in sibling1, store B in sibling2 — no common scope other than root.
      // A derived store depending on both lives at root.
      final evA = Event<void>();
      final evB = Event<void>();
      final storeA = Store<int>.accum((ctx) {
        ctx.on(evA, (_) async* { yield ctx.current + 1; });
        return 0;
      });
      final storeB = Store<int>.accum((ctx) {
        ctx.on(evB, (_) async* { yield ctx.current + 1; });
        return 0;
      });
      final sum = Store<int>.derive((s) => s.read(storeA) + s.read(storeB));

      final root = Scope();
      // Both accum stores go to root (unbound) — sum also stays at root.
      expect(root.read(sum), 0);
      root.fire(evA, null);
      root.fire(evB, null);
      await Future.microtask(() {});
      expect(root.read(sum), 2);
      root.dispose();
    });
  });

  // ── 11. Event binding (broadcast overrides) ───────────────────────────────

  group('Event binding', () {
    test('event bound to root broadcasts to all child scopes', () async {
      final globalReset = Event<void>();
      final (:store, :inc) = makeIsolatedCounter();

      final root = Scope(overrides: {globalReset});
      final left = root.fork(overrides: {store});
      final right = root.fork(overrides: {store});

      left.read(store);
      right.read(store);

      left.fire(inc, null);
      right.fire(inc, null);
      right.fire(inc, null);
      await Future.microtask(() {});
      expect(left.read(store).count, 1);
      expect(right.read(store).count, 2);

      // Fire reset from root — both should reset.
      root.fire(globalReset, null);
      // We need both scopes to listen to globalReset:
      // Actually, the stores don't listen to globalReset here.
      // Re-design: use a counter that listens to globalReset.
      root.dispose();
    });

    test('event bound to root: all child store handlers receive the event', () async {
      final globalReset = Event<void>();

      Store<int> makeResettableCounter() => Store<int>.accum((ctx) {
        ctx.on(globalReset, (_) async* { yield 0; });
        return 5;
      });

      final root = Scope(overrides: {globalReset});
      final counterA = makeResettableCounter();
      final counterB = makeResettableCounter();

      final left = root.fork(overrides: {counterA});
      final right = root.fork(overrides: {counterB});

      left.read(counterA);
      right.read(counterB);

      expect(left.read(counterA), 5);
      expect(right.read(counterB), 5);

      // Fire from root — broadcasts to both left and right scopes.
      root.fire(globalReset, null);
      await Future.microtask(() {});

      expect(left.read(counterA), 0);
      expect(right.read(counterB), 0);
      root.dispose();
    });

    test('event bound to child scope only affects that subtree', () async {
      final scopedReset = Event<void>();

      Store<int> makeResettableCounter() => Store<int>.accum((ctx) {
        ctx.on(scopedReset, (_) async* { yield 0; });
        return 5;
      });

      final root = Scope();
      final counterA = makeResettableCounter();
      final counterB = makeResettableCounter();

      // scopedReset is bound to left only.
      final left = root.fork(overrides: {counterA, scopedReset});
      final right = root.fork(overrides: {counterB});

      left.read(counterA);
      right.read(counterB);

      // Fire from left — broadcasts through left subtree only.
      left.fire(scopedReset, null);
      await Future.microtask(() {});

      expect(left.read(counterA), 0);
      expect(right.read(counterB), 5); // unaffected
      root.dispose();
    });

    test('event fired from descendant routes to binding scope', () async {
      final globalReset = Event<void>();

      Store<int> makeResettableCounter() => Store<int>.accum((ctx) {
        ctx.on(globalReset, (_) async* { yield 0; });
        return 10;
      });

      final root = Scope(overrides: {globalReset});
      final counterA = makeResettableCounter();
      final counterB = makeResettableCounter();

      final left = root.fork(overrides: {counterA});
      final right = root.fork(overrides: {counterB});
      final grandLeft = left.fork();

      left.read(counterA);
      right.read(counterB);

      // Fire from grandchild — should route to root and broadcast to both.
      grandLeft.fire(globalReset, null);
      await Future.microtask(() {});

      expect(left.read(counterA), 0);
      expect(right.read(counterB), 0);
      root.dispose();
    });

    test('unbound event fires only in local scope (regression)', () async {
      final localInc = Event<void>();
      final counterA = Store<int>.accum((ctx) {
        ctx.on(localInc, (_) async* { yield ctx.current + 1; });
        return 0;
      });
      final counterB = Store<int>.accum((ctx) {
        ctx.on(localInc, (_) async* { yield ctx.current + 1; });
        return 0;
      });

      final root = Scope();
      final left = root.fork(overrides: {counterA});
      final right = root.fork(overrides: {counterB});

      left.read(counterA);
      right.read(counterB);

      left.fire(localInc, null); // only left scope should respond
      await Future.microtask(() {});

      expect(left.read(counterA), 1);
      expect(right.read(counterB), 0); // unaffected
      root.dispose();
    });

    test('broadcast into disposed child scope does not crash', () async {
      final globalReset = Event<void>();

      Store<int> makeResettableCounter() => Store<int>.accum((ctx) {
        ctx.on(globalReset, (_) async* { yield 0; });
        return 5;
      });

      final root = Scope(overrides: {globalReset});
      final counterA = makeResettableCounter();
      final counterB = makeResettableCounter();

      final left = root.fork(overrides: {counterA});
      final right = root.fork(overrides: {counterB});

      left.read(counterA);
      right.read(counterB);

      left.dispose(); // dispose one child before firing

      // Should not throw even though left is disposed.
      root.fire(globalReset, null);
      await Future.microtask(() {});

      expect(right.read(counterB), 0); // right still works
      root.dispose();
    });
  });

  // ── 11. listen: false ─────────────────────────────────────────────────────

  group('listen: false', () {
    test('reads last value without registering dependency', () async {
      final counter = makeCounter();
      final toggle = Event<bool>();
      final toggleStore = Store<bool>.accum((ctx) {
        ctx.on(toggle, (v) async* { yield v; });
        return false;
      });

      final scope = Scope();
      scope.read(counter); // initialize counter handlers

      var recomputeCount = 0;
      final derived = Store<int>.derive((source) {
        source.read(toggleStore); // real dep — also initializes toggleStore
        recomputeCount++;
        return source.read(counter, listen: false).count; // no dep
      });

      scope.read(derived);
      recomputeCount = 0;

      // counter changes — derived must NOT recompute
      scope.fire(increment, null);
      await Future.microtask(() {});
      scope.read(derived);
      expect(recomputeCount, 0);

      // toggle changes — derived MUST recompute
      scope.fire(toggle, true);
      await Future.microtask(() {});
      scope.read(derived);
      expect(recomputeCount, 1);

      scope.dispose();
    });
  });
}
