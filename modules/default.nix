{
  lib,
  config,
  pkgs,
  ...
}:

let
  providers = lib.filterAttrs (_: v: v ? poll) config.futures;
  providerNames = lib.attrNames providers;
in
{
  imports = [
    ./providers/external.nix
    ./providers/exec.nix
    ./providers/fetch-tree.nix
    ./providers/npins.nix
  ];

  options.futures.stateDir = lib.mkOption {
    type = lib.types.path;
    description = "Base directory for futures state files (absolute path, used at Nix evaluation time)";
  };

  options.futures.pollPrelude = lib.mkOption {
    type = lib.types.lines;
    default = ''
      STATE_DIR="${toString config.futures.stateDir}"
      export STATE_DIR
    '';
    description = "Shell script prelude executed before polling. Should set STATE_DIR environment variable.";
  };

  options.futures.poll = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "Package that runs all provider poll scripts sequentially";
  };

  config.futures.poll = pkgs.writeShellScriptBin "futures-poll" ''
    set -e
    ${config.futures.pollPrelude}

    ${lib.concatMapStringsSep "\n" (
      name:
      # bash
      ''
        echo "Polling: ${name}"
        ${lib.getExe providers.${name}.poll}
        echo ""
      '') providerNames}
  '';
}
