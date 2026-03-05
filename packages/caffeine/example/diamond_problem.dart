import 'package:caffeine/caffeine.dart';

typedef User = ({String firstName, String lastName});

final user = Store<User, User>(
  (self) => (
    () => ((firstName: 'John', lastName: ''), () async* {}),
    (event, state) => (event, () async* {}),
  ),
);

final upperCasedFirstName = Stateful(($) => $(user).firstName.toUpperCase());

final upperCasedLastName = Stateful(($) => $(user).lastName.toUpperCase());

/// On [user] update, [upperCasedName] will update only once, compressing sync
/// and pure [Stateful] updates
final upperCasedName = Stateful(
  ($) => '${$(upperCasedFirstName)} ${$(upperCasedLastName)}',
);
