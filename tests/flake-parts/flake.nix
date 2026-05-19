{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-externals.url = "../..";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      { lib, config, ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ];

        imports = [
          inputs.nix-externals.flakeModule
          "${inputs.nix-externals}/examples/fetch-tree.nix"
        ];

        debug = true;

        # Top-level declarations: declared once, readable from any output.
        externals.stateDir = ./_externals;

        externals.test-gen.producer = ''
          echo '{ message = "hello from a bare external"; }' > "$OUT"
        '';
        externals.test-gen.cacheKey = "v1";

        fetch-tree.flake-root.input.github = {
          owner = "srid";
          repo = "flake-root";
        };

        fetch-tree.dotfiles.input = "github:mrene/dotfiles";

        perSystem =
          { pkgs, ... }:
          {
            # Outer `config` (top-level) is captured by closure — externals reads happen
            # without dipping into per-system state.
            packages.greeting = pkgs.writeText "greeting.txt" config.externals.test-gen.nixValue.message;

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
