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
  postPatch = ''
    sed -i '/^workspace:$/,$d' pubspec.yaml
    sed -i '/^resolution: workspace$/d' ${packageRoot}/pubspec.yaml
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

  installPhase = ''
    touch $out
    touch $pubcache
  '';
}
