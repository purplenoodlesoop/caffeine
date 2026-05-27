{
  flutter,
  mkCheck,
}:
mkCheck {
  pname = "flutter-caffeine-check";
  src = ../.;
  packageRoot = "packages/flutter_caffeine";
  builder = flutter.buildFlutterApplication;
  # `flutter test` invokes `flutter pub get` first; --no-pub (global flag)
  # skips that so the sandbox stays offline.
  testCommand = "flutter --no-pub test --reporter expanded";
}
