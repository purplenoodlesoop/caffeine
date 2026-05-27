{
  flutter,
  mkCheck,
}:
mkCheck {
  pname = "flutter-caffeine-check";
  src = ../.;
  packageRoot = "packages/flutter_caffeine";
  builder = flutter.buildFlutterApplication;
  # mk-check runs `dart pub get --offline` first; --no-pub then keeps
  # `flutter test` from re-fetching.
  testCommand = "flutter test --no-pub --reporter expanded";
}
