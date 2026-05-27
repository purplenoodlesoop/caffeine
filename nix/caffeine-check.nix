{
  buildDartApplication,
  mkCheck,
}:
mkCheck {
  pname = "caffeine-check";
  src = ../.;
  packageRoot = "packages/caffeine";
  builder = buildDartApplication;
  testCommand = "dart test --reporter expanded";
  filterSdk = true;
}
