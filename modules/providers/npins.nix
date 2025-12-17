# npins provider - syncs declared pins with an existing npins directory
# Allows users to declare pins as futures and manage them with npins CLI
{
  lib,
  config,
  pkgs,
  ...
}:
let
  # Freeform type for extra flags (string or bool values)
  extraFlagsType = lib.types.attrsOf (lib.types.either lib.types.str lib.types.bool);

  # Helper to create submodule with freeform support for unknown flags
  mkInputSubmodule =
    options:
    lib.types.submodule {
      freeformType = extraFlagsType;
      inherit options;
    };

  # Input type: tagged union matching npins add subcommands
  # Each submodule accepts extra attributes as flags
  npinsInputType = lib.types.attrTag {
    github = lib.mkOption {
      type = mkInputSubmodule {
        owner = lib.mkOption {
          type = lib.types.str;
          description = "Repository owner";
        };
        repo = lib.mkOption {
          type = lib.types.str;
          description = "Repository name";
        };
        branch = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Branch to track";
        };
      };
    };
    gitlab = lib.mkOption {
      type = mkInputSubmodule {
        owner = lib.mkOption {
          type = lib.types.str;
          description = "Repository owner";
        };
        repo = lib.mkOption {
          type = lib.types.str;
          description = "Repository name";
        };
        branch = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Branch to track";
        };
        host = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "GitLab instance host";
        };
      };
    };
    git = lib.mkOption {
      type = mkInputSubmodule {
        url = lib.mkOption {
          type = lib.types.str;
          description = "Git repository URL";
        };
        branch = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Branch to track";
        };
      };
    };
    pypi = lib.mkOption {
      type = mkInputSubmodule {
        name = lib.mkOption {
          type = lib.types.str;
          description = "Package name on PyPI";
        };
      };
    };
    channel = lib.mkOption {
      type = mkInputSubmodule {
        name = lib.mkOption {
          type = lib.types.str;
          description = "Nix channel name (e.g., nixos-24.05)";
        };
      };
    };
  };

  # Output type: npins source (has outPath)
  npinsSourceType = lib.mkOptionType {
    name = "npinsSource";
    description = "npins source (result of import npins-dir)";
    check = x: lib.isAttrs x && x ? outPath;
    merge = lib.mergeEqualOption;
  };

  # All npins futures (excluding poll and dir)
  npinsFutures = lib.filterAttrs (n: _: n != "poll" && n != "dir") config.futures.npins;

  # Positional args per type - everything else becomes a flag automatically
  # To add a new type, add an entry here and to npinsInputType above
  positionalArgs = {
    github = [
      "owner"
      "repo"
    ];
    gitlab = [
      "owner"
      "repo"
    ];
    git = [ "url" ];
    pypi = [ "name" ];
    channel = [ "name" ];
  };

  # Convert input to npins add command arguments
  mkAddCommand =
    name: input:
    lib.concatStrings (
      lib.mapAttrsToList (
        typeName: attrs:
        let
          positional = positionalArgs.${typeName};
          # Filter out empty strings and internal attrs
          cleanAttrs = lib.filterAttrs (n: v: !(lib.isString v && v == "") && n != "_module") attrs;
          posArgs = map (a: lib.escapeShellArg cleanAttrs.${a}) positional;
          flagAttrs = lib.filterAttrs (n: _: !lib.elem n positional) cleanAttrs;
        in
        lib.concatStringsSep " " (
          [ typeName ] ++ posArgs ++ [ (lib.cli.toGNUCommandLineShell { } flagAttrs) ]
        )
      ) (removeAttrs input [ "_module" ])
    );
in
{
  options.futures.npins = lib.mkOption {
    type = lib.types.submodule {
      options = {
        dir = lib.mkOption {
          type = lib.types.path;
          description = "Path to the npins directory (containing default.nix and sources.json)";
        };
        poll = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          description = "Package that polls/adds missing npins";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.npins;
          description = "The npins package to use for managing pins";
        };
      };
      freeformType = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          let
            npinsSources = import config.futures.npins.dir;
          in
          {
            options = {
              input = lib.mkOption { type = npinsInputType; };
              ready = lib.mkOption {
                type = lib.types.bool;
                readOnly = true;
              };
              value = lib.mkOption {
                type = npinsSourceType;
                readOnly = true;
              };
            };
            config = {
              ready = npinsSources ? ${name};
              value =
                if npinsSources ? ${name} then
                  npinsSources.${name}
                else
                  throw "Future '${name}' not ready. Run 'nix run .#futures-poll' to add pin.";
            };
          }
        )
      );
    };
    default = { };
  };

  config.futures.npins.poll =
    let
      notReady = lib.filterAttrs (_: cfg: !cfg.ready) npinsFutures;
      notReadyNames = lib.attrNames notReady;
      npinsDir = toString config.futures.npins.dir;
    in
    pkgs.writeShellScriptBin "poll-npins" ''
      set -e
      echo "npins provider:"
      ${
        if notReadyNames == [ ] then
          ''echo "  All ready"''
        else
          lib.concatMapStringsSep "\n" (
            name:
            let
              addCmd = mkAddCommand name npinsFutures.${name}.input;
            in
            ''
              echo -n "  ${name}: "
              ${lib.getExe config.futures.npins.package} add ${addCmd} --name ${name} -d ${npinsDir}
              echo "done"
            ''
          ) notReadyNames
      }
    '';
}
