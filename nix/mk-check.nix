{
  lib,
  runCommand,
  yq-go,
}:
{
  pname,
  version ? "3.0.0",
  src,
  packageRoot,
  builder,
  testCommand,
  # When true, drop `source: sdk` packages from the lockfile before passing it
  # in. Pure-Dart packages don't need Flutter SDK entries the workspace
  # lockfile carries on behalf of sibling Flutter packages.
  filterSdk ? false,
}:
let
  pubspecLockJson =
    runCommand "${pname}-pubspec.lock.json" { nativeBuildInputs = [ yq-go ]; }
      "yq -o=json . ${src}/pubspec.lock > $out";

  fullLock = lib.importJSON pubspecLockJson;
  pubspecLock =
    if filterSdk then
      fullLock
      // {
        packages = lib.filterAttrs (_: pkg: (pkg.source or "") != "sdk") fullLock.packages;
      }
    else
      fullLock;

  # On-disk pubspec.lock kept in sync with the (possibly filtered) attrset.
  # Without this, pub.Entrypoint.ensureUpToDate sees a mismatch between
  # pubspec.lock and .dart_tool/package_config.json and tries to re-resolve
  # against pub.dev (no network in the sandbox).
  filteredLockYaml = runCommand "${pname}-pubspec.lock" {
    nativeBuildInputs = [ yq-go ];
    passAsFile = [ "data" ];
    data = builtins.toJSON pubspecLock;
  } "yq -P < \"$dataPath\" > $out";
in
builder {
  inherit
    pname
    version
    src
    packageRoot
    pubspecLock
    ;

  dontDartBuild = true;
  dontDartInstall = true;

  # Strip workspace metadata so dart/flutter test resolves only this package
  # instead of walking siblings (which would need a Flutter SDK or pub-get).
  # Also rewrite pubspec.lock to match the filtered attrset.
  postPatch = ''
    sed -i '/^workspace:$/,$d' pubspec.yaml
    sed -i '/^resolution: workspace$/d' ${packageRoot}/pubspec.yaml
    install -m 644 ${filteredLockYaml} pubspec.lock
  '';

  # Skip any builder-supplied build step (e.g. `flutter build linux` for the
  # Linux Flutter variant, which looks for lib/main.dart). We only run tests.
  buildPhase = ''
    runHook preBuild
    runHook postBuild
  '';

  doCheck = true;
  # dart/flutter test rewrite .dart_tool/package_config.json on startup; copy
  # to a writable dir so the symlinks back into /nix/store don't block it.
  checkPhase = ''
    runHook preCheck
    cp -rL . "$TMPDIR/src"
    chmod -R u+w "$TMPDIR/src"
    cd "$TMPDIR/src/${packageRoot}"
    HOME=$TMPDIR ${testCommand}
    runHook postCheck
  '';

  # Touch every declared output (Flutter's Linux variant adds `debug`).
  # No runHook — dartInstallCacheHook would otherwise try `mkdir $pubcache`
  # over our touched file. We're bypassing the builder's install entirely.
  installPhase = ''
    for o in $outputs; do
      eval "touch \$$o"
    done
  '';
}
