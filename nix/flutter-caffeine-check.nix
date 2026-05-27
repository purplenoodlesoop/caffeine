{
  flutter,
  lib,
  runCommand,
  yq-go,
}:
let
  pubspecLockJson =
    runCommand "flutter-caffeine-pubspec.lock.json" { nativeBuildInputs = [ yq-go ]; }
      "yq -o=json . ${../pubspec.lock} > $out";
in
flutter.buildFlutterApplication {
  pname = "flutter-caffeine-check";
  version = "3.0.0";

  src = ../.;
  packageRoot = "packages/flutter_caffeine";
  pubspecLock = lib.importJSON pubspecLockJson;

  dontDartBuild = true;
  dontDartInstall = true;

  # flutter test would otherwise traverse the workspace and try to pub-get
  # flutter_caffeine_example, which conflicts with the sandboxed Flutter SDK.
  postPatch = ''
    sed -i '/^workspace:$/,$d' pubspec.yaml
    sed -i '/^resolution: workspace$/d' packages/flutter_caffeine/pubspec.yaml
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    cp -rL . "$TMPDIR/src"
    chmod -R u+w "$TMPDIR/src"
    cd "$TMPDIR/src/packages/flutter_caffeine"
    HOME=$TMPDIR flutter test --reporter expanded
    runHook postCheck
  '';

  installPhase = ''
    touch $out
    touch $pubcache
  '';
}
