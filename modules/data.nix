# Pure data layer for nix-externals. No `pkgs` dependency, so it can be imported
# at any level of a flake-parts tree (including top-level) and consumed from
# `nixosConfigurations`, `flake.*`, or other non-perSystem outputs.
{ lib, config, ... }:
let
  topConfig = config;

  stateDirSubmodule = lib.types.submodule {
    options = {
      evalPath = lib.mkOption {
        type = lib.types.path;
        description = "Nix path used at evaluation time for `pathExists` checks.";
      };
    };
  };

  stateDirType = lib.types.coercedTo lib.types.path (p: { evalPath = p; }) stateDirSubmodule;

  externalEntry =
    { name, config, ... }:
    let
      stateDir = topConfig.externals.stateDir.evalPath;
      valuePath = "${toString stateDir}/${config.filename}";
      cacheKeyFile = "${toString stateDir}/${name}.cacheKey";
      storedKey =
        if builtins.pathExists cacheKeyFile then
          lib.removeSuffix "\n" (builtins.readFile cacheKeyFile)
        else
          null;
      ready = builtins.pathExists valuePath && (config.cacheKey == null || storedKey == config.cacheKey);
      notReadyThrow =
        accessor:
        throw "external '${name}'.${accessor} not ready. Run 'nix run .#externals-run' to materialize.";
    in
    {
      options = {
        producer = lib.mkOption {
          # `anything` rather than a narrower string-or-function type: the module system's
          # `functionTo` / `either` wrap function definitions to support definition-merging
          # semantics that don't fit here — we want the bare value stored as-is and dispatch
          # on `isFunction` at aggregator time.
          type = lib.types.anything;
          description = ''
            Shell snippet that materializes this external. Either a plain string or a function
            `pkgs: string` — the framework resolves the function with the aggregator's `pkgs`
            when building the runner. The framework exports `$OUT` pointing at
            `$STATE_DIR/${config.filename}` and `$STATE_DIR` for sidecar files. Write the
            resolved artifact to `$OUT`. The framework only invokes the producer when the
            external is not yet ready, so no in-script self-skip is needed.
          '';
        };
        filename = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = ''
            Basename of the artifact under `stateDir`. Defaults to the external's name with no
            extension. Override for ecosystem conventions (e.g. `deps.nix`, `lock.json`).
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
        path = lib.mkOption {
          type = lib.types.str;
          default = valuePath;
          readOnly = true;
          description = ''
            Absolute path to `$STATE_DIR/${config.filename}`. Always populated, regardless of
            `ready`. Consumers that need to read the artifact themselves (or pass it to another
            tool) use this directly.
          '';
        };
        ready = lib.mkOption {
          type = lib.types.bool;
          default = ready;
          readOnly = true;
          description = ''
            True iff the artifact at `path` exists and, when `cacheKey` is set, the matching
            `$STATE_DIR/${name}.cacheKey` sidecar holds the same string.
          '';
        };
        stringValue = lib.mkOption {
          type = lib.types.str;
          default =
            if ready then lib.removeSuffix "\n" (builtins.readFile valuePath) else notReadyThrow "stringValue";
          readOnly = true;
          description = ''
            Contents of the artifact as a string, trailing newline trimmed. Throws when not
            ready. For raw bytes (newline included), read `path` directly.
          '';
        };
        jsonValue = lib.mkOption {
          type = lib.types.anything;
          default =
            if ready then builtins.fromJSON (builtins.readFile valuePath) else notReadyThrow "jsonValue";
          readOnly = true;
          description = "Artifact parsed as JSON via `builtins.fromJSON`. Throws when not ready.";
        };
        nixValue = lib.mkOption {
          type = lib.types.anything;
          default = if ready then import valuePath else notReadyThrow "nixValue";
          readOnly = true;
          description = "Artifact loaded via `import`. Throws when not ready.";
        };
      };
    };
in
{
  options.externals = lib.mkOption {
    description = ''
      Registry of externally-resolved values. Each `externals.<name>` declares a `producer`
      that writes an artifact to `$OUT`; the framework exposes `path`, `ready`, and the lazy
      decoders `stringValue` / `jsonValue` / `nixValue` for consumers to read it back.
    '';
    default = { };
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf (lib.types.submodule externalEntry);
      options = {
        stateDir = lib.mkOption {
          type = stateDirType;
          description = ''
            Where externals materialize their state. A bare path is coerced into `evalPath`,
            which is used for eval-time `pathExists` checks. The runtime write location is
            owned by the layer that builds the aggregator (`modules/default.nix` derives it
            from `evalPath`; the flake-parts integration overrides it via `flake-root`).
          '';
        };
      };
    };
  };
}
