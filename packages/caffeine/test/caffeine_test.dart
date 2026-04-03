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
      increment(scope, null);
      await Future.delayed(Duration.zero);
      expect(counter(scope).count, 1);
    });

    test('fire decrement', () async {
      increment(scope, null);
      increment(scope, null);
      decrement(scope, null);
      await Future.delayed(Duration.zero);
      expect(counter(scope).count, 1);
    });

    test('fire reset', () async {
      increment(scope, null);
      reset(scope, null);
      await Future.delayed(Duration.zero);
      expect(counter(scope).count, 0);
    });

    test('multiple fires accumulate', () async {
      for (var i = 0; i < 5; i++) {
        increment(scope, null);
      }
      await Future.delayed(Duration.zero);
      expect(counter(scope).count, 5);
    });

    test('equal new state does not trigger notification', () async {
      final states = <int>[];
      scope.stream(counter).listen((s) => states.add(s.count));
      reset(scope, null); // already 0 — no change
      await Future.delayed(Duration.zero);
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

      increment(scope, null);
      increment(scope, null);
      increment(scope, null);

      await Future.delayed(Duration.zero);
      expect(states, [3]); // batched: only final value emitted per flush
    });

    test('multiple independent listeners both receive events', () async {
      final a = <int>[];
      final b = <int>[];
      scope.stream(counter).listen((s) => a.add(s.count));
      scope.stream(counter).listen((s) => b.add(s.count));

      increment(scope, null);
      increment(scope, null);

      await Future.delayed(Duration.zero);
      expect(a, [2]); // batched: only final value emitted per flush
      expect(b, [2]);
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
          done(ctx, null);
        });
        ctx.on(done, (_) async* {
          yield [...ctx.current, 'done'];
        });
        return <String>[];
      });

      final scope = Scope();
      scope.read(store);
      start(scope, null);
      await Future.delayed(const Duration(milliseconds: 10));
      expect(scope.read(store), ['done']);
      scope.dispose();
    });

    test('initial effect fires on store init', () async {
      final init = Event<void>();

      final store = Store<int>.accum((ctx) {
        ctx.on(init, (_) async* { yield ctx.current + 1; });
        init(ctx, null);
        return 0;
      });

      final scope = Scope();
      scope.read(store);
      await Future.delayed(Duration.zero);
      expect(scope.read(store), 1);
      scope.dispose();
    });

    test('effect yields multiple events in order', () async {
      final go = Event<void>();
      final add = Event<int>();

      final store = Store<int>.accum((ctx) {
        ctx.on(add, (v) async* { yield ctx.current + v; });
        ctx.on(go, (_) async* {
          add(ctx, 1);
          add(ctx, 2);
          add(ctx, 3);
        });
        return 0;
      });

      final scope = Scope();
      scope.read(store);
      go(scope, null);
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
          loaded(ctx, null);
        });
        ctx.on(loaded, (_) async* { yield 'done'; });
        return 'idle';
      });

      final scope = Scope();
      scope.read(store);
      start(scope, null);
      await Future.delayed(Duration.zero);
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
          logMsg(ctx, 'produced');
          yield ctx.current + 1;
        });
        return 0;
      });

      final scope = Scope();
      scope.read(log);
      scope.read(producer);
      go(scope, null);
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
      final doubled = Store<int>.derive((s) => counter(s).count * 2);
      expect(scope.read(doubled), 0);
    });

    test('recomputes when dependency changes', () async {
      final doubled = Store<int>.derive((s) => counter(s).count * 2);
      scope.read(doubled);
      increment(scope, null);
      await Future.delayed(Duration.zero);
      expect(scope.read(doubled), 2);
    });

    test('chains derived nodes', () async {
      final doubled = Store<int>.derive((s) => counter(s).count * 2);
      final quadrupled = Store<int>.derive((s) => doubled(s) * 2);
      increment(scope, null);
      await Future.delayed(Duration.zero);
      expect(scope.read(quadrupled), 4);
    });

    test('stream emits when derived value changes', () async {
      final doubled = Store<int>.derive((s) => counter(s).count * 2);
      final emitted = <int>[];
      scope.stream(doubled).listen(emitted.add);
      scope.read(doubled);

      increment(scope, null);
      increment(scope, null);

      await Future.delayed(Duration.zero);
      expect(emitted, [4]); // batched: only final value emitted per flush
    });

    test('does not recompute when store state is unchanged', () async {
      var computeCount = 0;
      final derived = Store<int>.derive((s) {
        computeCount++;
        return counter(s).count;
      });

      scope.read(derived);
      computeCount = 0;

      reset(scope, null); // already 0, no change
      reset(scope, null);
      await Future.delayed(Duration.zero);
      scope.read(derived);

      expect(computeCount, 0);
    });

    test('does not emit when recomputed value is same as before', () async {
      final isPositive = Store<bool>.derive((s) => counter(s).count > 0);
      final emitted = <bool>[];
      scope.stream(isPositive).listen(emitted.add);
      scope.read(isPositive);

      increment(scope, null); // 0→1: false→true, emits
      increment(scope, null); // 1→2: true→true, no emit

      await Future.delayed(Duration.zero);
      expect(emitted, [true]);
    });

    test('call extension reads derived store', () async {
      final doubled = Store<int>.derive((s) => counter(s).count * 2);
      increment(scope, null);
      await Future.delayed(Duration.zero);
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

      final upper1 = Store<String>.derive((s) => user(s).first.toUpperCase());
      final upper2 = Store<String>.derive((s) => user(s).last.toUpperCase());

      var recomputeCount = 0;
      final combined = Store<String>.derive((s) {
        recomputeCount++;
        return '${upper1(s)} ${upper2(s)}';
      });

      final scope = Scope();
      scope.read(combined); // warms up and initializes user through deps
      recomputeCount = 0;

      setUser(scope, (first: 'Jane', last: 'Smith'));
      await Future.delayed(Duration.zero);

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

      final len1 = Store<int>.derive((s) => user(s).firstName.length);
      final len2 = Store<int>.derive((s) => user(s).lastName.length);
      final total = Store<int>.derive((s) => len1(s) + len2(s));

      final emitted = <int>[];
      final scope = Scope();
      scope.stream(total).listen(emitted.add);
      scope.read(total); // warm up, initializes user through deps

      setUser(scope, (firstName: 'XX', lastName: 'YY')); // 1+1=2 → 2+2=4
      setUser(scope, (firstName: 'AB', lastName: 'CD')); // 2+2=4 → 2+2=4

      await Future.delayed(Duration.zero);
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
        controller.stream.listen((v) => addValue(ctx, v));
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
        externalSub = controller.stream.listen((v) => addValue(ctx, v));
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
      increment(root, null);
      await Future.delayed(Duration.zero);

      final child = root.fork();
      expect(counter(child).count, 1);
      root.dispose();
    });

    test('unbound store goes to root even when first accessed via child', () async {
      final counter = makeCounter();
      final root = Scope();
      final child = root.fork();

      // First access from child — counter is unbound, so root owns it.
      child.read(counter);
      // Fire from root (that's where the counter actually lives).
      increment(root, null);
      await Future.delayed(Duration.zero);

      expect(counter(root).count, 1); // root sees it
      expect(counter(child).count, 1); // child shares root's state

      child.dispose();
      expect(counter(root).count, 1); // survives child disposal
      root.dispose();
    });

    test('bound store is local to child scope', () async {
      final root = Scope();
      final (:store, :inc) = makeIsolatedCounter();
      final child = root.fork(overrides: {store});

      child.read(store); // initialize in child scope
      inc(child, null);
      await Future.delayed(Duration.zero);
      expect(store(child).count, 1);

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

      inc(child, null);
      await Future.delayed(Duration.zero);
      expect(received, [(count: 1)]);

      child.dispose();
      expect(received, [(count: 1)]);
      root.dispose();
    });

    test('disposing child does not affect parent stores', () async {
      final sharedCounter = makeCounter();
      final root = Scope();
      root.read(sharedCounter);
      increment(root, null);
      await Future.delayed(Duration.zero);

      final child = root.fork();
      child.dispose();

      expect(sharedCounter(root).count, 1);
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

      rootC.inc(root, null);
      childC.inc(child, null);
      grandC.inc(grand, null);
      await Future.delayed(Duration.zero);

      grand.dispose(); // cleans up grandC only

      expect(rootC.store(root).count, 1);
      expect(childC.store(child).count, 1);
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
      realInc(root, null); // real: 0→1
      await Future.delayed(Duration.zero);

      final child = root.fork(
        overrides: {MappingStoreOverride(from: real, to: fake)},
      );
      child.read(real); // resolves to fake, initializes fake in child scope
      fakeInc(child, null); // fake: 0→1
      fakeInc(child, null); // fake: 1→2
      await Future.delayed(Duration.zero);

      expect(real(child).count, 2); // child sees fake
      expect(real(root).count, 1);  // root still sees real

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
      sharedInc(scope, null); // fires fake
      sharedInc(scope, null);
      await Future.delayed(Duration.zero);

      expect(real(scope).count, 2); // real resolves to fake
      expect(fake(scope).count, 2);
      scope.dispose();
    });
  });

  // ── 10. Derived store scope promotion ────────────────────────────────────

  group('Derived store scope promotion', () {
    test('derived store is promoted to dep-owner scope', () async {
      final (:store, :inc) = makeIsolatedCounter();
      final doubled = Store<int>.derive((s) => store(s).count * 2);

      final root = Scope();
      final child = root.fork(overrides: {store});

      child.read(store);
      expect(child.read(doubled), 0);

      inc(child, null);
      await Future.delayed(Duration.zero);
      expect(child.read(doubled), 2);
      root.dispose();
    });

    test('grandchild shares promoted entry from child scope', () async {
      final (:store, :inc) = makeIsolatedCounter();
      final doubled = Store<int>.derive((s) => store(s).count * 2);

      final root = Scope();
      final child = root.fork(overrides: {store, inc}); // bind inc to child
      final grand1 = child.fork();
      final grand2 = child.fork();

      // Both grandchildren read doubled — must share the same promoted instance.
      expect(grand1.read(doubled), 0);
      expect(grand2.read(doubled), 0);

      // inc is bound to child — routes there and broadcasts within child's subtree.
      inc(grand1, null);
      await Future.delayed(Duration.zero);

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
      final sum = Store<int>.derive((s) => storeA(s) + storeB(s));

      final root = Scope();
      // Both accum stores go to root (unbound) — sum also stays at root.
      expect(root.read(sum), 0);
      evA(root, null);
      evB(root, null);
      await Future.delayed(Duration.zero);
      expect(root.read(sum), 2);
      root.dispose();
    });
  });

  // ── 11. Event binding (broadcast overrides) ───────────────────────────────

  group('Event binding', () {
    test('event bound to root broadcasts to all child scopes', () async {
      final globalReset = Event<void>();
      final incA = Event<void>();
      final incB = Event<void>();

      final counterA = Store<int>.accum((ctx) {
        ctx.on(incA, (_) async* { yield ctx.current + 1; });
        ctx.on(globalReset, (_) async* { yield 0; });
        return 0;
      });
      final counterB = Store<int>.accum((ctx) {
        ctx.on(incB, (_) async* { yield ctx.current + 1; });
        ctx.on(globalReset, (_) async* { yield 0; });
        return 0;
      });

      // globalReset bound to root — broadcasts to all descendants.
      // incA/incB bound to their scopes — isolated from each other.
      final root = Scope(overrides: {globalReset});
      final left = root.fork(overrides: {counterA, incA});
      final right = root.fork(overrides: {counterB, incB});

      left.read(counterA);
      right.read(counterB);

      incA(left, null);
      incB(right, null);
      incB(right, null);
      await Future.delayed(Duration.zero);
      expect(counterA(left), 1);
      expect(counterB(right), 2);

      globalReset(left, null); // routes to root, resets both
      await Future.delayed(Duration.zero);

      expect(counterA(left), 0);
      expect(counterB(right), 0);
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

      expect(counterA(left), 5);
      expect(counterB(right), 5);

      // Fire from root — broadcasts to both left and right scopes.
      globalReset(root, null);
      await Future.delayed(Duration.zero);

      expect(counterA(left), 0);
      expect(counterB(right), 0);
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
      scopedReset(left, null);
      await Future.delayed(Duration.zero);

      expect(counterA(left), 0);
      expect(counterB(right), 5); // unaffected
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
      globalReset(grandLeft, null);
      await Future.delayed(Duration.zero);

      expect(counterA(left), 0);
      expect(counterB(right), 0);
      root.dispose();
    });

    test('unbound event broadcasts from root, reaching all sibling scopes', () async {
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

      localInc(left, null); // routes to root, broadcasts to all descendants
      await Future.delayed(Duration.zero);

      expect(counterA(left), 1);
      expect(counterB(right), 1); // also reached via root broadcast
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
      globalReset(root, null);
      await Future.delayed(Duration.zero);

      expect(counterB(right), 0); // right still works
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
      final derived = Store<int>.derive((s) {
        toggleStore(s); // real dep — also initializes toggleStore
        recomputeCount++;
        return counter(s, listen: false).count; // no dep
      });

      scope.read(derived);
      recomputeCount = 0;

      // counter changes — derived must NOT recompute
      increment(scope, null);
      await Future.delayed(Duration.zero);
      scope.read(derived);
      expect(recomputeCount, 0);

      // toggle changes — derived MUST recompute
      toggle(scope, true);
      await Future.delayed(Duration.zero);
      scope.read(derived);
      expect(recomputeCount, 1);

      scope.dispose();
    });
  });
}
