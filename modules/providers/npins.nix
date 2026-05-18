# npins provider - syncs declared pins with an existing npins directory
{
  lib,
  config,
  pkgs,
  ...
}:
let
  extraFlagsType = lib.types.attrsOf (lib.types.either lib.types.str lib.types.bool);

  mkInputSubmodule =
    options:
    lib.types.submodule {
      freeformType = extraFlagsType;
      inherit options;
    };

  # Input type: tagged union matching npins add subcommands.
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

  npinsSourceType = lib.mkOptionType {
    name = "npinsSource";
    description = "npins source (result of import npins-dir)";
    check = x: lib.isAttrs x && x ? outPath;
    merge = lib.mergeEqualOption;
  };

  # Positional args per type - everything else becomes a flag automatically.
  # To add a new type, add an entry here and to npinsInputType above.
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

  mkAddCommand =
    input:
    lib.concatStrings (
      lib.mapAttrsToList (
        typeName: attrs:
        let
          positional = positionalArgs.${typeName};
          cleanAttrs = lib.filterAttrs (n: v: !(lib.isString v && v == "") && n != "_module") attrs;
          posArgs = map (a: lib.escapeShellArg cleanAttrs.${a}) positional;
          flagAttrs = lib.filterAttrs (n: _: !lib.elem n positional) cleanAttrs;
        in
        lib.concatStringsSep " " (
          [ typeName ] ++ posArgs ++ [ (lib.cli.toGNUCommandLineShell { } flagAttrs) ]
        )
      ) (removeAttrs input [ "_module" ])
    );

  mkSubmodule =
    { name, ... }:
    let
      npinsSources = import config.npins.dir;
      ready = npinsSources ? ${name};
    in
    {
      options = {
        input = lib.mkOption {
          type = npinsInputType;
          description = "Tagged union matching `npins add <type>` subcommands.";
        };
        ready = lib.mkOption {
          type = lib.types.bool;
          default = ready;
        };
        value = lib.mkOption {
          type = npinsSourceType;
          default =
            if ready then
              npinsSources.${name}
            else
              throw "npins '${name}' not ready. Run 'nix run .#externals-poll' to add pin.";
        };
      };
    };

  pins = lib.filterAttrs (
    n: _:
    !(builtins.elem n [
      "dir"
      "package"
    ])
  ) config.npins;
  notReady = lib.filterAttrs (_: cfg: !cfg.ready) pins;
in
{
  options.npins = lib.mkOption {
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf (lib.types.submodule mkSubmodule);
      options = {
        dir = lib.mkOption {
          type = lib.types.path;
          description = "Path to the npins directory (containing default.nix and sources.json).";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.npins;
          description = "The npins package used to manage pins.";
        };
      };
    };
    default = { };
    description = "Pins declared inline; the npins CLI is invoked to materialize missing entries.";
  };

  config.externals.producers = lib.mapAttrs' (
    name: cfg:
    let
      addCmd = mkAddCommand cfg.input;
      npinsDir = toString config.npins.dir;
    in
    lib.nameValuePair "npins-${name}" (
      pkgs.writeShellApplication {
        name = "npins-${name}";
        text = ''
          ${lib.getExe config.npins.package} add ${addCmd} --name ${name} -d ${npinsDir}
        '';
      }
    )
  ) notReady;
}
