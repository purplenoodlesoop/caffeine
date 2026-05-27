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

  # Pin the on-disk lockfile to the filtered attrset (preConfigure later
  # replaces it with a JSON serialization of the same attrset; either way
  # it stays consistent with what dartConfigHook builds). We do NOT strip
  # the workspace here — dartConfigHook needs the workspace declaration
  # so workspacePackageConfigScript adds member entries (caffeine,
  # flutter_caffeine, flutter_caffeine_example) to package_config.json.
  postPatch = ''
    install -m 644 ${filteredLockYaml} pubspec.lock
  '';

  # Skip any builder-supplied build step (e.g. `flutter build linux` for the
  # Linux Flutter variant, which looks for lib/main.dart). We only run tests.
  buildPhase = ''
    runHook preBuild
    runHook postBuild
  '';

  doCheck = true;
  # `dart test` / `flutter test` start by calling pub.Entrypoint.ensureUpToDate
  # which hits pub.dev (no network in the sandbox). The dartConfigHook ships a
  # `packageRun` bash helper that invokes `dart --packages=... <pkg>/bin/<name>.dart`
  # directly, skipping pub. Use it where possible (see caffeine-check.nix).
  # `cp -rL` first so the symlinked .dart_tool/package_config.json is writable.
  checkPhase = ''
    runHook preCheck
    cp -rL . "$TMPDIR/src"
    chmod -R u+w "$TMPDIR/src"
    # Strip workspace metadata only AFTER dartConfigHook has populated
    # package_config.json — otherwise the workspace members won't get added.
    # Without stripping, the test runner would re-traverse the workspace and
    # try to pub-get the Flutter example.
    sed -i '/^workspace:$/,$d' "$TMPDIR/src/pubspec.yaml"
    sed -i '/^resolution: workspace$/d' "$TMPDIR/src/${packageRoot}/pubspec.yaml"
    # dartConfigHook drops .dart_tool/ at the workspace root, but tests run
    # from the package dir, and packageRun's `jq .dart_tool/package_config.json`
    # is path-relative. Copy it into the package dir so packageRun resolves.
    cp -rL "$TMPDIR/src/.dart_tool" "$TMPDIR/src/${packageRoot}/"
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
