# fetch-tree example - resolves fetchTree inputs to locked source trees.
#
# Producer writes a self-contained Nix expression to $STATE_DIR/fetch-tree-<name>.nix
# of the form `builtins.fetchTree (builtins.fromJSON ''<locked-json>'')`. Framework reads
# it back as `externals.fetch-tree-<name>.value`; this module also exposes a thin proxy
# at `fetch-tree.<name>.value` for callers that prefer the per-provider namespace.
{
  lib,
  config,
  pkgs,
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

  # String → fetchTree attrs via parseFlakeRef; attrTag → tagged-name plus its fields.
  toFetchTreeInput =
    input:
    if lib.isString input then
      builtins.parseFlakeRef input
    else
      let
        typeName = lib.head (lib.attrNames input);
        attrs = input.${typeName};
        cleanAttrs = lib.filterAttrs (n: v: !(lib.isString v && v == "") && n != "_module") attrs;
      in
      cleanAttrs // { type = typeName; };

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
        ready = lib.mkOption {
          type = lib.types.bool;
          default = config.externals.${extKey}.ready;
          readOnly = true;
          description = "True iff the locked tree has been materialized.";
        };
        value = lib.mkOption {
          type = sourceTreeType;
          default = config.externals.${extKey}.value;
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

  config.externals = lib.mapAttrs' (
    name: cfg:
    let
      inputFile = pkgs.writeText "fetch-tree-${name}-input.json" (
        builtins.toJSON (toFetchTreeInput cfg.input)
      );
    in
    lib.nameValuePair "fetch-tree-${name}" {
      producer = ''
        locked=$(${pkgs.nix}/bin/nix-instantiate --eval --strict --json --expr "
          let
            input = builtins.fromJSON (builtins.readFile ${inputFile});
            tree = builtins.fetchTree input;
            locked = { narHash = tree.narHash; }
              // (if tree ? rev then { rev = tree.rev; } else { });
          in input // locked
        ")
        cat > "$OUT" <<NIX_EOF
        builtins.fetchTree (builtins.fromJSON '''
        $locked
        ''')
        NIX_EOF
      '';
    }
  ) config.fetch-tree;
}
