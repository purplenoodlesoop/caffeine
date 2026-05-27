{
  buildDartApplication,
  mkCheck,
}:
mkCheck {
  pname = "caffeine-check";
  src = ../.;
  packageRoot = "packages/caffeine";
  builder = buildDartApplication;
  # mk-check rewrites pubspec.lock to match the filtered attrset, so
  # pub.Entrypoint.ensureUpToDate is satisfied without touching pub.dev.
  testCommand = "dart run test:test --reporter expanded";
  filterSdk = true;
}
