{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-futures.url = "../..";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      { lib, ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ];

        imports = [ inputs.nix-futures.flakeModule ];

        debug = true;

        perSystem =
          { pkgs, config, ... }:
          {
            futures.stateDir = ./_futures;
            futures.external.greeting.input = { };
            futures.external.pending.input = { };
            futures.exec.test-gen.input = pkgs.writeShellScriptBin "generate" ''
              echo "generating config..."
              echo '{ message = "hello from exec"; }' > config.nix
            '';
            futures.fetch-tree.flake-root.input.github = {
              owner = "srid";
              repo = "flake-root";
            };

            futures.fetch-tree.dotfiles.input = "github:mrene/dotfiles";
            packages.my-dotfiles = lib.mkMerge [
              (lib.mkIf config.futures.fetch-tree.dotfiles.ready (
                pkgs.runCommand "my-dotfiles" { } ''
                  ln -s ${config.futures.fetch-tree.dotfiles.value} $out
                ''
              ))
              (lib.mkIf (!config.futures.fetch-tree.dotfiles.ready) (
                pkgs.runCommand "empty-dotfiles" { } ''
                  mkdir -p $out
                ''
              ))
            ];
          };
      }
    );
}
