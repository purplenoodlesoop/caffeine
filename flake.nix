{
  description = "Caffeine — a reactive microstore for Dart and Flutter.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    core-flake = {
      url = "github:purplenoodlesoop/core-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      core-flake,
      ...
    }:
    let
      base = core-flake.lib.evalFlake {
        perSystem =
          { pkgs, ... }:
          {
            flake.shell = [
              pkgs.dart
              pkgs.flutter
            ];
          };
      };

      perSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          mkCheck = pkgs.callPackage ./nix/mk-check.nix { };

          packageChecks =
            {
              caffeine = pkgs.callPackage ./nix/caffeine-check.nix { inherit mkCheck; };
            }
            # buildFlutterApplication has no macOS support upstream; gate accordingly.
            // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
              flutter-caffeine = pkgs.callPackage ./nix/flutter-caffeine-check.nix { inherit mkCheck; };
            };

          ci-yaml = (pkgs.formats.yaml { }).generate "ci.yml" (import ./nix/ci.nix);

          sync-ci = pkgs.writeShellApplication {
            name = "sync-ci";
            runtimeInputs = [ pkgs.git ];
            text = ''
              root="$(git rev-parse --show-toplevel)"
              target="$root/.github/workflows/ci.yml"
              mkdir -p "$(dirname "$target")"
              install -m 644 ${ci-yaml} "$target"
              echo "Wrote $target"
            '';
          };

          ci-up-to-date = pkgs.runCommand "ci-up-to-date" { } ''
            if ! diff -u ${./.github/workflows/ci.yml} ${ci-yaml}; then
              echo
              echo "❌ .github/workflows/ci.yml is out of sync with nix/ci.nix."
              echo "   Run: nix run .#sync-ci"
              exit 1
            fi
            touch $out
          '';
        in
        {
          packages = {
            inherit ci-yaml;
          };
          apps.sync-ci = {
            type = "app";
            program = "${sync-ci}/bin/sync-ci";
          };
          checks = packageChecks // {
            inherit ci-up-to-date;
          };
        }
      );
    in
    nixpkgs.lib.recursiveUpdate base perSystem;
}
