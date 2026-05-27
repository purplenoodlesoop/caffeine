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
      checks = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          checks =
            {
              caffeine = pkgs.callPackage ./nix/caffeine-check.nix { };
            }
            # buildFlutterApplication has no macOS support upstream; gate accordingly.
            // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
              flutter-caffeine = pkgs.callPackage ./nix/flutter-caffeine-check.nix { };
            };
        }
      );
    in
    nixpkgs.lib.recursiveUpdate base checks;
}
