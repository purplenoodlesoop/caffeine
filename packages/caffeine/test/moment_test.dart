import 'package:caffeine/caffeine.dart';
import 'package:test/test.dart';

final closed = Event<String>(debugLabel: 'closed');
final noted = Event<String>(debugLabel: 'noted');

final tabs = Store<List<String>>.accum((ctx) {
  ctx.on(closed, (id) async* {
    yield [...ctx.current.where((t) => t != id)];
  });
  return ['a', 'b'];
}, debugLabel: 'tabs');

final count = tabs.select((t) => t.length, debugLabel: 'count');

final archive = Store<List<String>>.accum((ctx) {
  ctx.on(closed, (id) async* {
    yield [...ctx.current, '$id from ${ctx.read(tabs)} of ${ctx.read(count)}'];
  });
  return [];
}, debugLabel: 'archive');

final later = Store<List<String>>.accum((ctx) {
  ctx.on(closed, (id) async* {
    await Future<void>.delayed(Duration.zero);
    yield [...ctx.current, 'after: ${ctx.read(tabs)}'];
  });
  return [];
}, debugLabel: 'later');

final echo = Store<List<String>>.accum((ctx) {
  ctx.on(noted, (text) async* {
    yield [...ctx.current, '$text with ${ctx.read(tabs)}'];
  });
  return [];
}, debugLabel: 'echo');

final announcing = Store<List<String>>.accum((ctx) {
  ctx.on(closed, (id) async* {
    yield [...ctx.current, id];
    yield [...ctx.current, 'own: ${ctx.current.length}'];
    await ctx.fire(noted, 'announced');
  });
  return [];
}, debugLabel: 'announcing');

final announced = Store<List<String>>.accum((ctx) {
  ctx.on(noted, (text) async* {
    yield [...ctx.current, '$text saw ${ctx.read(announcing)}'];
  });
  return [];
}, debugLabel: 'announced');

void main() {
  group('one event, several stores', () {
    test(
      'a store reads the others as they were when the event fired',
      () async {
        final scope = Scope()
          ..read(tabs)
          ..read(archive);
        await scope.fire(closed, 'a');
        expect(scope.read(archive), ['a from [a, b] of 2']);
        expect(scope.read(tabs), ['b']);
      },
    );

    test('which store was created first does not matter', () async {
      final scope = Scope()
        ..read(archive)
        ..read(tabs);
      await scope.fire(closed, 'a');
      expect(scope.read(archive), ['a from [a, b] of 2']);
    });

    test('after its first wait a handler sees the event applied', () async {
      final scope = Scope()
        ..read(later)
        ..read(tabs);
      await scope.fire(closed, 'a');
      expect(scope.read(later), ['after: [b]']);
    });

    test('a store sees its own yields at once', () async {
      final scope = Scope()
        ..read(announced)
        ..read(announcing);
      await scope.fire(closed, 'a');
      expect(scope.read(announcing), ['a', 'own: 1']);
    });

    test(
      'a store that fires an event shows its change to the handlers',
      () async {
        final scope = Scope()
          ..read(announced)
          ..read(announcing);
        await scope.fire(closed, 'a');
        expect(scope.read(announced), ['announced saw [a, own: 1]']);
      },
    );

    test('an event fired after another sees the first applied', () async {
      final scope = Scope()
        ..read(echo)
        ..read(tabs);
      await scope.fire(closed, 'a');
      await scope.fire(noted, 'then');
      expect(scope.read(echo), ['then with [b]']);
    });

    test('a stream hears the change once, after the event', () async {
      final scope = Scope()
        ..read(archive)
        ..read(tabs);
      final heard = <List<String>>[];
      scope.stream(tabs).listen(heard.add);
      await scope.fire(closed, 'a');
      expect(heard, [
        ['b'],
      ]);
    });
  });
}
