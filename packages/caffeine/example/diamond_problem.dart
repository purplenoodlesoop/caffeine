import 'package:caffeine/caffeine.dart';

typedef User = ({String firstName, String lastName});

final setUser = Event<User>();

final user = Store<User>.accum((ctx) {
  ctx.on(setUser, (u) async* { yield u; });
  return (firstName: 'John', lastName: '');
});

final upperCasedFirstName =
    Store<String>.derive((s) => user(s).firstName.toUpperCase());

final upperCasedLastName =
    Store<String>.derive((s) => user(s).lastName.toUpperCase());

/// On [user] update, [upperCasedName] will update only once, compressing sync
/// and pure [Store.derive] updates.
final upperCasedName = Store<String>.derive(
  (s) => '${upperCasedFirstName(s)} ${upperCasedLastName(s)}',
);
