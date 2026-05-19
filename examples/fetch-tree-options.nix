# fetch-tree options - declares the `fetch-tree.<name>` namespace.
#
# Each entry takes either a flake URL string or structured fetchTree attrs and exposes `ready`
# and `value` proxied off the matching `externals.fetch-tree-<name>` entry written by the
# producer in fetch-tree.nix.
{
  lib,
  config,
  ...
}:
let
  fetchTreeAttrsType = lib.types.attrTag {
    github = lib.mkOption {
      type = lib.types.submodule {
        options = {
          owner = lib.mkOption {
            type = lib.types.str;
            description = "Repository owner";
          };
          repo = lib.mkOption {
            type = lib.types.str;
            description = "Repository name";
          };
          rev = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Git revision (commit hash)";
          };
          ref = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Git reference (branch/tag)";
          };
          host = lib.mkOption {
            type = lib.types.str;
            default = "github.com";
            description = "GitHub host";
          };
        };
      };
    };
    gitlab = lib.mkOption {
      type = lib.types.submodule {
        options = {
          owner = lib.mkOption {
            type = lib.types.str;
            description = "Repository owner";
          };
          repo = lib.mkOption {
            type = lib.types.str;
            description = "Repository name";
          };
          rev = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Git revision (commit hash)";
          };
          ref = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Git reference (branch/tag)";
          };
          host = lib.mkOption {
            type = lib.types.str;
            default = "gitlab.com";
            description = "GitLab host";
          };
        };
      };
    };
    sourcehut = lib.mkOption {
      type = lib.types.submodule {
        options = {
          owner = lib.mkOption {
            type = lib.types.str;
            description = "Repository owner";
          };
          repo = lib.mkOption {
            type = lib.types.str;
            description = "Repository name";
          };
          rev = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Git revision (commit hash)";
          };
          ref = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Git reference (branch/tag)";
          };
          host = lib.mkOption {
            type = lib.types.str;
            default = "sr.ht";
            description = "Sourcehut host";
          };
        };
      };
    };
    git = lib.mkOption {
      type = lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Git repository URL";
          };
          rev = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Git revision (commit hash)";
          };
          ref = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Git reference (branch/tag)";
          };
          shallow = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Shallow clone";
          };
          submodules = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Fetch submodules";
          };
          allRefs = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Fetch all refs";
          };
        };
      };
    };
    mercurial = lib.mkOption {
      type = lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Mercurial repository URL";
          };
          rev = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Mercurial revision";
          };
          ref = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Mercurial reference";
          };
        };
      };
    };
    tarball = lib.mkOption {
      type = lib.types.submodule {
        options.url = lib.mkOption {
          type = lib.types.str;
          description = "Tarball URL";
        };
      };
    };
    file = lib.mkOption {
      type = lib.types.submodule {
        options.url = lib.mkOption {
          type = lib.types.str;
          description = "File URL";
        };
      };
    };
    path = lib.mkOption {
      type = lib.types.submodule {
        options.path = lib.mkOption {
          type = lib.types.path;
          description = "Local filesystem path";
        };
      };
    };
  };

  fetchTreeInputType = lib.types.either lib.types.str fetchTreeAttrsType;

  sourceTreeType = lib.mkOptionType {
    name = "sourceTree";
    description = "Nix source tree (result of builtins.fetchTree)";
    check = x: lib.isAttrs x && x ? outPath;
    merge = lib.mergeEqualOption;
  };

  mkSubmodule =
    { name, ... }:
    let
      extKey = "fetch-tree-${name}";
    in
    {
      options = {
        input = lib.mkOption {
          type = fetchTreeInputType;
          description = "Flake URL string or structured fetchTree reference.";
        };
        cacheKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Optional cache-bust string forwarded to the underlying external. Bump it to force
            a re-lock without changing `input`. See `externals.<name>.cacheKey`.
          '';
        };
        ready = lib.mkOption {
          type = lib.types.bool;
          default = config.externals.${extKey}.ready;
          readOnly = true;
          description = "True iff the locked tree has been materialized.";
        };
        value = lib.mkOption {
          type = sourceTreeType;
          default = builtins.fetchTree config.externals.${extKey}.jsonValue;
          description = "The locked source tree, available once `nix run .#externals-run` has run.";
        };
      };
    };
in
{
  options.fetch-tree = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule mkSubmodule);
    default = { };
    description = "Externals resolved through builtins.fetchTree, producing locked source trees.";
  };
}
