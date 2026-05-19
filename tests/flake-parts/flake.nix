{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-externals.url = "../..";
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

        imports = [ inputs.nix-externals.flakeModule ];

        debug = true;

        perSystem =
          { pkgs, config, ... }:
          {
            imports = [ "${inputs.nix-externals}/examples/fetch-tree.nix" ];

            externals.stateDir = ./_externals;

            externals.test-gen.producer = ''
              echo '{ message = "hello from a bare external"; }' > "$OUT"
            '';
            externals.test-gen.cacheKey = "v1";

            packages.greeting = pkgs.writeText "greeting.txt" config.externals.test-gen.value.message;

            fetch-tree.flake-root.input.github = {
              owner = "srid";
              repo = "flake-root";
            };

            fetch-tree.dotfiles.input = "github:mrene/dotfiles";

            packages.my-dotfiles = lib.mkMerge [
              (lib.mkIf config.fetch-tree.dotfiles.ready (
                pkgs.runCommand "my-dotfiles" { } ''
                  ln -s ${config.fetch-tree.dotfiles.value} $out
                ''
              ))
              (lib.mkIf (!config.fetch-tree.dotfiles.ready) (
                pkgs.runCommand "empty-dotfiles" { } ''
                  mkdir -p $out
                ''
              ))
            ];
          };
      }
    );
}
