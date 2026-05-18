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
            run the aggregator from within the live source tree. Integrations like flake-parts
            override this to compute the live working-tree path at runtime (e.g. via `flake-root`).
          '';
        };
      };
    }
  );

  stateDirType = lib.types.coercedTo lib.types.path (p: { evalPath = p; }) stateDirSubmodule;

  externalEntry =
    { name, ... }:
    let
      valueFile = "${toString config.externals.stateDir.evalPath}/${name}.nix";
      ready = builtins.pathExists valueFile;
    in
    {
      options = {
        producer = lib.mkOption {
          type = lib.types.package;
          description = ''
            Script that materializes this external. Must write a Nix expression to
            `$STATE_DIR/${name}.nix` on success. Expected to be idempotent — running it again
            when the file already exists should be a no-op.
          '';
        };
        ready = lib.mkOption {
          type = lib.types.bool;
          default = ready;
          readOnly = true;
          description = "True iff `$STATE_DIR/${name}.nix` exists at evaluation time.";
        };
        value = lib.mkOption {
          type = lib.types.anything;
          default =
            if ready then
              import valueFile
            else
              throw "external '${name}' not ready. Run 'nix run .#externals-run' to materialize.";
          description = "Result of `import \"$STATE_DIR/${name}.nix\"`. Throws when not ready.";
        };
      };
    };

  # Producers are freeform externals.<name> entries; typed sub-options (stateDir, run,
  # and any added by wrappers like relativeStateDir) are excluded by shape.
  producers = lib.filterAttrs (_: v: lib.isAttrs v && v ? producer) config.externals;
  notReady = lib.filterAttrs (_: cfg: !cfg.ready) producers;
in
{
  options.externals = lib.mkOption {
    description = ''
      Registry of externally-resolved values. Each `externals.<name>` declares a `producer` script
      that writes `$STATE_DIR/<name>.nix`; the framework reads that file back as `value` and
      reports `ready` based on its presence.
    '';
    default = { };
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf (lib.types.submodule externalEntry);
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
        run = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          description = "Aggregator that runs producers for entries not yet ready.";
        };
      };
    };
  };

  config.externals.run = pkgs.writeShellApplication {
    name = "externals-run";
    text = ''
      STATE_DIR=${config.externals.stateDir.runtimePath}
      export STATE_DIR
      mkdir -p "$STATE_DIR"
      ${lib.concatMapStringsSep "\n" (name: ''
        echo "Running: ${name}"
        ${lib.getExe notReady.${name}.producer}
      '') (lib.attrNames notReady)}
    '';
  };
}
