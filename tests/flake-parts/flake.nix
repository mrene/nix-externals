{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-futures.url = "../..";
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

      imports = [ inputs.nix-futures.flakeModule ];

      perSystem =
        { ... }:
        {
          futures.stateDir = ./_futures;
          futures.external.greeting.input = { };
          futures.external.pending.input = { };
        };
    };
}
