{
  description = "nix-externals - declare values that need external resolution";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-root.url = "github:srid/flake-root";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        {
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt
              pkgs.deadnix
              pkgs.nix-unit
            ];
          };

          checks.unit =
            pkgs.runCommand "nix-unit-tests"
              {
                nativeBuildInputs = [ pkgs.nix-unit ];
              }
              ''
                export HOME=$TMPDIR
                export NIX_PATH=nixpkgs=${pkgs.path}
                nix-unit \
                  --eval-store "$HOME" \
                  --extra-experimental-features 'nix-command flakes' \
                  ${inputs.self}/tests/nix-unit.nix
                touch $out
              '';
        };

      flake = {
        flakeModule = inputs.flake-parts.lib.importApply ./flake-module.nix {
          inherit (inputs) flake-root;
        };
        lib = import ./lib;
      };
    };
}
