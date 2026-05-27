import 'package:caffeine/caffeine.dart';

// Events
const increment = Event<void>(debugLabel: 'increment');
const setBy = Event<int>(debugLabel: 'setBy');
const resetAll = Event<void>(debugLabel: 'resetAll');

// Accum store: counter with three handlers.
final counter = Store<int>.accum(
  (ctx) {
    ctx.on(increment, (_) async* {
      yield ctx.current + 1;
    });
    ctx.on(setBy, (delta) async* {
      yield ctx.current + delta;
    });
    ctx.on(resetAll, (_) async* {
      yield 0;
    });
    return 0;
  },
  debugLabel: 'counter',
);

// Derived store: doubled view of counter. Recomputed automatically.
final doubled = counter.select((c) => c * 2, debugLabel: 'doubled');

Future<void> main() async {
  // resetAll is bound to the root scope — fires from anywhere broadcast here.
  final root = Scope(overrides: {resetAll});

  // Listen for state changes.
  root.stream(counter).listen((v) => print('counter -> $v'));
  root.stream(doubled).listen((v) => print('doubled -> $v'));

  // Fire some events.
  increment(root);
  increment(root);
  setBy(root, 5);
  await Future.delayed(Duration.zero);
  print('counter is ${root.read(counter)}, doubled is ${root.read(doubled)}');

  resetAll(root);
  await Future.delayed(Duration.zero);
  print('after reset: counter=${root.read(counter)}');

  root.dispose();
}
