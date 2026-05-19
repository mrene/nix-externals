# flake-parts module for nix-externals.
#
# Declarations and reads live at the top level (so consumers can read external
# values from `nixosConfigurations`, `flake.*`, or any other non-perSystem output).
# Only the aggregator package is per-system, since building it requires `pkgs`.
{ flake-root }:
{
  flake-parts-lib,
  config,
  lib,
  ...
}:
let
  inherit (flake-parts-lib) mkPerSystemOption;
  topConfig = config;
in
{
  imports = [
    flake-root.flakeModule
    ./modules/data.nix
  ];

  options.externals.relativeStateDir = lib.mkOption {
    type = lib.types.str;
    default = "_externals";
    description = "Path relative to the flake root where state is materialized at runtime.";
  };

  options.perSystem = mkPerSystemOption (
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      producers = lib.filterAttrs (_: v: lib.isAttrs v && v ? producer) topConfig.externals;
      notReady = lib.filterAttrs (_: cfg: !cfg.ready) producers;
      resolveProducer = cfg: if lib.isFunction cfg.producer then cfg.producer pkgs else cfg.producer;
      producerDrvs = lib.mapAttrs (
        name: cfg:
        pkgs.writeShellApplication {
          inherit name;
          text = resolveProducer cfg;
        }
      ) notReady;
    in
    {
      options.externals = {
        runtimePath = lib.mkOption {
          type = lib.types.str;
          description = ''
            Shell expression evaluated at runtime to the writable state directory. Defaults
            to a path under `flake-root` joined with `externals.relativeStateDir`.
          '';
        };
        run = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          description = "Aggregator that runs producers for entries not yet ready.";
        };
      };

      config.externals.runtimePath = /* bash */ ''
        "$(${lib.getExe config.flake-root.package})/${topConfig.externals.relativeStateDir}"
      '';

      config.externals.run = pkgs.writeShellApplication {
        name = "externals-run";
        text = ''
          STATE_DIR=${config.externals.runtimePath}
          export STATE_DIR
          mkdir -p "$STATE_DIR"
          ${lib.concatMapStringsSep "\n" (name: ''
            echo "Running: ${name}"
            OUT="$STATE_DIR/${notReady.${name}.filename}"
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

      config.packages.externals-run = config.externals.run;
    }
  );
}
