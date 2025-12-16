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
        { pkgs, ... }:
        {
          futures.stateDir = ./_futures;
          futures.external.greeting.input = { };
          futures.external.pending.input = { };
          futures.exec.test-gen.input = [
            (pkgs.writeShellScriptBin "generate" ''
              echo "generating config..."
              echo '{ message = "hello from exec"; }' > config.nix
            '')
          ];
        };
    };
}
