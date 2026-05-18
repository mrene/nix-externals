# exec provider - runs a derivation or shell snippet in a per-entry working directory
{
  lib,
  config,
  pkgs,
  ...
}:
let
  stateDir = "${toString config.externals.stateDir}/exec";

  mkSubmodule =
    { name, ... }:
    let
      futureDir = stateDir + "/${name}";
      markerFile = futureDir + "/.ready";
      ready = builtins.pathExists markerFile;
    in
    {
      options = {
        input = lib.mkOption {
          type = lib.types.either lib.types.str lib.types.package;
          description = "Shell snippet or derivation to run. Working directory is per-entry.";
        };
        ready = lib.mkOption {
          type = lib.types.bool;
          default = ready;
        };
        value = lib.mkOption {
          type = lib.types.path;
          default =
            if ready then
              futureDir
            else
              throw "exec '${name}' not ready. Run 'nix run .#externals-poll' to execute.";
        };
      };
    };

  notReady = lib.filterAttrs (_: cfg: !cfg.ready) config.exec;
in
{
  options.exec = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule mkSubmodule);
    default = { };
    description = "Externals materialized by running a shell snippet or derivation.";
  };

  config.externals.producers = lib.mapAttrs' (
    name: cfg:
    let
      executable =
        if builtins.isString cfg.input then
          pkgs.writeShellScriptBin "exec-${name}" cfg.input
        else
          cfg.input;
      futureDir = ''"$STATE_DIR/exec/${name}"'';
    in
    lib.nameValuePair "exec-${name}" (
      pkgs.writeShellApplication {
        name = "exec-${name}";
        text = ''
          mkdir -p ${futureDir}
          cd ${futureDir}
          if ${lib.getExe executable}; then
            touch ${futureDir}/.ready
          else
            echo "exec '${name}': failed" >&2
            exit 1
          fi
        '';
      }
    )
  ) notReady;
}
