# Example external provider which is also used for unit testing
{
  lib,
  config,
  pkgs,
  ...
}:
let
  futures = import ../../lib { inherit lib; };
  stateDir = "${config.futures.stateDir}/external";
in
{
  options.futures.external = lib.mkOption {
    type = futures.mkProvider {
      inputType = lib.types.attrs;
      mkConfig =
        { name }:
        let
          stateFile = stateDir + "/${name}.nix";
          ready = builtins.pathExists stateFile;
        in
        {
          inherit ready;
          value =
            if ready then
              import stateFile
            else
              throw "Future '${name}' not ready. Create ${toString stateFile} with the desired resolved value.";
        };
    };
    default = { };
  };

  config.futures.external.poll =
    let
      allFutures = lib.filterAttrs (n: _: n != "poll") config.futures.external;
      notReady = lib.filterAttrs (_: cfg: !cfg.ready) allFutures;
      notReadyList = lib.attrNames notReady;
    in
    pkgs.writeShellScriptBin "poll-external" ''
      echo "External provider:"
      ${
        if notReadyList == [ ] then
          ''echo "  All ready"''
        else
          lib.concatMapStringsSep "\n" (
            name: ''echo "  ${name}: create $STATE_DIR/external/${name}.nix"''
          ) notReadyList
      }
    '';
}
