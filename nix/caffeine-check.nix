{
  buildDartApplication,
  lib,
  runCommand,
  yq-go,
}:
let
  pubspecLockJson =
    runCommand "caffeine-pubspec.lock.json" { nativeBuildInputs = [ yq-go ]; }
      "yq -o=json . ${../pubspec.lock} > $out";
  fullLock = lib.importJSON pubspecLockJson;
  # The workspace lockfile carries Flutter SDK packages on behalf of
  # flutter_caffeine; caffeine itself never touches them, so drop them here so
  # buildDartApplication doesn't demand a Flutter SDK source builder.
  caffeineLock = fullLock // {
    packages = lib.filterAttrs (_: pkg: (pkg.source or "") != "sdk") fullLock.packages;
  };
in
buildDartApplication {
  pname = "caffeine-check";
  version = "3.0.0";

  src = ../.;
  packageRoot = "packages/caffeine";
  pubspecLock = caffeineLock;

  dontDartBuild = true;
  dontDartInstall = true;

  # dart test would otherwise traverse the workspace and choke on
  # flutter_caffeine_example, which needs the Flutter SDK.
  postPatch = ''
    sed -i '/^workspace:$/,$d' pubspec.yaml
    sed -i '/^resolution: workspace$/d' packages/caffeine/pubspec.yaml
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    # dart test rewrites .dart_tool/package_config.json on startup; copy to a
    # writable dir so the symlinks back into /nix/store don't block it.
    cp -rL . "$TMPDIR/src"
    chmod -R u+w "$TMPDIR/src"
    cd "$TMPDIR/src/packages/caffeine"
    HOME=$TMPDIR dart test --reporter expanded
    runHook postCheck
  '';

  installPhase = ''
    touch $out
    touch $pubcache
  '';
}
