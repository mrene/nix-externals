{
  lib,
  config,
  pkgs,
  ...
}:
let
  stateDirSubmodule = lib.types.submodule (
    { config, ... }:
    {
      options = {
        evalPath = lib.mkOption {
          type = lib.types.path;
          description = "Nix path used at evaluation time for `pathExists` checks.";
        };
        runtimePath = lib.mkOption {
          type = lib.types.str;
          default = lib.escapeShellArg (toString config.evalPath);
          description = ''
            Shell expression evaluated at runtime to the writable state directory. The default
            uses `evalPath` verbatim, which is correct when consumers pass an absolute path or
            run the poll script from within the live source tree. Integrations like flake-parts
            override this to compute the live working-tree path at runtime (e.g. via `flake-root`).
          '';
        };
      };
    }
  );

  stateDirType = lib.types.coercedTo lib.types.path (p: { evalPath = p; }) stateDirSubmodule;
in
{
  imports = [
    ./providers/exec.nix
    ./providers/fetch-tree.nix
    ./providers/npins.nix
  ];

  options.externals = lib.mkOption {
    description = ''
      Configuration and registry for externally-resolved values.

      Provider modules add producer scripts under `externals.producers.<key>`. The aggregator
      at `externals.poll` runs every entry. Each script is expected to be idempotent and to
      write its result under `$STATE_DIR` at runtime.
    '';
    default = { };
    type = lib.types.submodule {
      options = {
        stateDir = lib.mkOption {
          type = stateDirType;
          description = ''
            Where externals materialize their state. Either a bare path (used for both eval-time
            `pathExists` checks and the runtime write location), or a submodule splitting the two:

            ```nix
            externals.stateDir = ./_externals;                # simple
            externals.stateDir.evalPath = ./_externals;       # explicit
            externals.stateDir.runtimePath = "$(some-cmd)";   # override runtime resolution
            ```
          '';
        };
        producers = lib.mkOption {
          type = lib.types.attrsOf lib.types.package;
          default = { };
          description = ''
            Registry of producer scripts. Each key maps to a derivation whose executable is
            invoked by the poll aggregator.
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
      export STATE_DIR=${config.externals.stateDir.runtimePath}
      mkdir -p "$STATE_DIR"
      ${lib.concatMapStringsSep "\n" (name: ''
        echo "Running: ${name}"
        ${lib.getExe config.externals.producers.${name}}
      '') (lib.attrNames config.externals.producers)}
    '';
  };
}
