{
  buildDartApplication,
  mkCheck,
}:
mkCheck {
  pname = "caffeine-check";
  src = ../.;
  packageRoot = "packages/caffeine";
  builder = buildDartApplication;
  # packageRun is a bash helper dartConfigHook installs; it invokes the test
  # package's bin/test.dart directly via `dart --packages=...`, completely
  # bypassing pub.Entrypoint.ensureUpToDate (and the pub.dev network probe).
  testCommand = "packageRun test --reporter expanded";
  filterSdk = true;
}
