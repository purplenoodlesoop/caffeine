{
  flutter,
  mkCheck,
}:
mkCheck {
  pname = "flutter-caffeine-check";
  src = ../.;
  packageRoot = "packages/flutter_caffeine";
  builder = flutter.buildFlutterApplication;
  testCommand = "flutter test --reporter expanded";
}
