{
  lib,
  config,
  pkgs,
  ...
}:
{
  imports = [
    ./providers/exec.nix
    ./providers/fetch-tree.nix
    ./providers/npins.nix
  ];

  options.externals = lib.mkOption {
    description = ''
      Configuration for declaring values resolved by external programs.

      Provider modules add producer scripts under `externals.producers.<key>`.
      The `poll` aggregator runs every producer in turn. Each script is expected
      to be idempotent and to write its result under `$STATE_DIR` at runtime.
    '';
    default = { };
    type = lib.types.submodule {
      options = {
        stateDir = lib.mkOption {
          type = lib.types.path;
          description = "Path where externals materialize their state (used at Nix evaluation time).";
        };
        pollPrelude = lib.mkOption {
          type = lib.types.lines;
          default = ''
            export STATE_DIR=${lib.escapeShellArg (toString config.externals.stateDir)}
          '';
          description = ''
            Shell prelude prepended to the poll aggregator. Must export `STATE_DIR`
            to the absolute path where producers should write at runtime.

            The default uses the Nix-level `stateDir` directly, which is correct for
            absolute paths set by bare evalModules consumers. The flake-parts entry
            overrides this to compute the path via `flake-root` at runtime.
          '';
        };
        producers = lib.mkOption {
          type = lib.types.attrsOf lib.types.package;
          default = { };
          description = ''
            Registry of producer scripts. Each key maps to a derivation whose
            executable is invoked by the poll aggregator.
          '';
        };
        poll = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          description = "Aggregator script that runs every producer in `externals.producers`.";
        };
      };
    };
  };

  config.externals.poll = pkgs.writeShellApplication {
    name = "externals-poll";
    text = ''
      ${config.externals.pollPrelude}
      mkdir -p "$STATE_DIR"
      ${lib.concatMapStringsSep "\n" (name: ''
        echo "Running: ${name}"
        ${lib.getExe config.externals.producers.${name}}
      '') (lib.attrNames config.externals.producers)}
    '';
  };
}
