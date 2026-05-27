{
  flutter,
  mkCheck,
}:
mkCheck {
  pname = "flutter-caffeine-check";
  src = ../.;
  packageRoot = "packages/flutter_caffeine";
  builder = flutter.buildFlutterApplication;
  # `flutter test` invokes `flutter pub get` first; --no-pub (subcommand
  # flag, not global) skips that so the sandbox stays offline.
  testCommand = "flutter test --no-pub --reporter expanded";
}
