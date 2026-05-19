{
  lib,
  config,
  pkgs,
  ...
}:
let
  topConfig = config;

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
    { name, config, ... }:
    let
      stateDir = topConfig.externals.stateDir.evalPath;
      valueFile = "${toString stateDir}/${name}.nix";
      cacheKeyFile = "${toString stateDir}/${name}.cacheKey";
      storedKey =
        if builtins.pathExists cacheKeyFile then
          lib.removeSuffix "\n" (builtins.readFile cacheKeyFile)
        else
          null;
      ready = builtins.pathExists valueFile && (config.cacheKey == null || storedKey == config.cacheKey);
    in
    {
      options = {
        producer = lib.mkOption {
          type = lib.types.str;
          description = ''
            Shell snippet that materializes this external. The framework exports `$OUT` pointing
            at `$STATE_DIR/${name}.nix` and `$STATE_DIR` for sidecar files. Write the resolved
            Nix expression to `$OUT`. The framework only invokes the producer when the external
            is not yet ready, so no in-script self-skip is needed.
          '';
        };
        cacheKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Opt-in cache-bust value. When set, the framework writes the literal string to
            `$STATE_DIR/${name}.cacheKey` after the producer succeeds and compares it on the
            next evaluation: a mismatch (or missing sidecar) flips `ready` back to false so
            the next `externals-run` re-invokes the producer. Bump this string whenever you
            need to force re-materialization. `null` disables the check (default).
          '';
        };
        ready = lib.mkOption {
          type = lib.types.bool;
          default = ready;
          readOnly = true;
          description = ''
            True iff `$STATE_DIR/${name}.nix` exists and, when `cacheKey` is set, the matching
            `$STATE_DIR/${name}.cacheKey` sidecar holds the same string.
          '';
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

  producerDrvs = lib.mapAttrs (
    name: cfg:
    pkgs.writeShellApplication {
      inherit name;
      text = cfg.producer;
    }
  ) notReady;
in
{
  options.externals = lib.mkOption {
    description = ''
      Registry of externally-resolved values. Each `externals.<name>` declares a `producer` snippet
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
        OUT="$STATE_DIR/${name}.nix"
        export OUT
        ${lib.getExe producerDrvs.${name}}
        ${
          if notReady.${name}.cacheKey == null then
            ''rm -f "$STATE_DIR/${name}.cacheKey"''
          else
            ''printf '%s' ${lib.escapeShellArg notReady.${name}.cacheKey} > "$STATE_DIR/${name}.cacheKey"''
        }
      '') (lib.attrNames producerDrvs)}
    '';
  };
}
