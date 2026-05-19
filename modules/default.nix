# Data + aggregator for nix-externals. Imports the pure data layer (`./data.nix`) and
# adds `externals.runtimePath` plus the `externals.run` aggregator package, both of
# which depend on `pkgs`. Bare evalModules / NixOS / home-manager consumers import
# this file; flake-parts users get the data layer at the top level and an aggregator
# built directly inside the flake-parts perSystem (see `flake-module.nix`).
{
  lib,
  config,
  pkgs,
  ...
}:
let
  producers = lib.filterAttrs (_: v: lib.isAttrs v && v ? producer) config.externals;
  notReady = lib.filterAttrs (_: cfg: !cfg.ready) producers;

  resolveProducer =
    cfg: if lib.isFunction cfg.producer then pkgs.callPackage cfg.producer { } else cfg.producer;

  producerDrvs = lib.mapAttrs (
    name: cfg:
    pkgs.writeShellApplication {
      inherit name;
      text = resolveProducer cfg;
    }
  ) notReady;
in
{
  imports = [ ./data.nix ];

  options.externals = lib.mkOption {
    type = lib.types.submodule {
      options = {
        runtimePath = lib.mkOption {
          type = lib.types.str;
          default = lib.escapeShellArg (toString config.externals.stateDir.evalPath);
          description = ''
            Shell expression evaluated at runtime to the writable state directory. The default
            uses `stateDir.evalPath` verbatim, which is correct when consumers pass an absolute
            path or run the aggregator from within the live source tree. Integrations like
            flake-parts override this to compute the live working-tree path at runtime (e.g.
            via `flake-root`).
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
}
