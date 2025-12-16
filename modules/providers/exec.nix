# Exec provider - executes derivations in state directory
{
  lib,
  config,
  pkgs,
  ...
}:
let
  futures = import ../../lib { inherit lib; };
  stateDir = config.futures.stateDir + "/exec";
in
{
  options.futures.exec = lib.mkOption {
    type = futures.mkProvider {
      inputType = lib.types.listOf lib.types.package;
      valueType = lib.types.path;
      mkConfig =
        { name }:
        let
          futureDir = stateDir + "/${name}";
          markerFile = futureDir + "/.ready";
          ready = builtins.pathExists markerFile;
        in
        {
          inherit ready;
          value =
            if ready then
              futureDir
            else
              throw "Future '${name}' not ready. Run 'nix run .#futures-poll' to execute.";
        };
    };
    default = { };
  };

  config.futures.exec.poll =
    let
      allFutures = lib.filterAttrs (n: _: n != "poll") config.futures.exec;
      notReady = lib.filterAttrs (_: cfg: !cfg.ready) allFutures;
      notReadyNames = lib.attrNames notReady;
    in
    pkgs.writeShellScript "poll-exec" ''
      echo "Exec provider:"
      ${
        if notReadyNames == [ ] then
          ''echo "  All ready"''
        else
          lib.concatMapStringsSep "\n" (
            name:
            let
              executables = allFutures.${name}.input;
              futureDir = "$STATE_DIR/exec/${name}";
            in
            ''
              echo -n "  ${name}: "
              mkdir -p ${futureDir}
              cd ${futureDir}
              if ${lib.concatMapStringsSep " && " (exe: ''${lib.getExe exe}'') executables}; then
                touch ${futureDir}/.ready
                echo "done"
              else
                echo "failed"
              fi
            ''
          ) notReadyNames
      }
    '';
}
