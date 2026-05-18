# fetch-tree provider - resolves fetchTree inputs to locked source trees
{
  lib,
  config,
  pkgs,
  ...
}:
let
  stateDir = "${toString config.externals.stateDir.evalPath}/fetch-tree";

  # Structured input type: tagged union of fetchTree input types.
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

  # Either a flake URL string or structured attrs.
  fetchTreeInputType = lib.types.either lib.types.str fetchTreeAttrsType;

  sourceTreeType = lib.mkOptionType {
    name = "sourceTree";
    description = "Nix source tree (result of builtins.fetchTree)";
    check = x: lib.isAttrs x && x ? outPath;
    merge = lib.mergeEqualOption;
  };

  # Convert input to fetchTree attrs format.
  # String: "github:owner/repo" -> { type = "github"; owner; repo; }
  # AttrTag: { github = { owner, repo, ... }; } -> { type = "github"; owner; repo; ... }
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
    { name, config, ... }:
    let
      resultFile = stateDir + "/${name}/result.json";
      ready = builtins.pathExists resultFile;
    in
    {
      options = {
        input = lib.mkOption {
          type = fetchTreeInputType;
          description = "Flake URL string or structured fetchTree reference.";
        };
        ready = lib.mkOption {
          type = lib.types.bool;
          default = ready;
        };
        value = lib.mkOption {
          type = sourceTreeType;
          default =
            if ready then
              let
                locked = builtins.fromJSON (builtins.readFile resultFile);
                lockedAttrs = lib.filterAttrs (
                  n: _:
                  builtins.elem n [
                    "narHash"
                    "rev"
                  ]
                ) locked;
                input = toFetchTreeInput config.input;
              in
              builtins.fetchTree (input // lockedAttrs)
            else
              throw "fetch-tree '${name}' not ready. Run 'nix run .#externals-poll' to fetch.";
        };
      };
    };

  notReady = lib.filterAttrs (_: cfg: !cfg.ready) config.fetch-tree;
in
{
  options.fetch-tree = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule mkSubmodule);
    default = { };
    description = "Externals resolved through builtins.fetchTree, producing locked source trees.";
  };

  config.externals.producers = lib.mapAttrs' (
    name: cfg:
    let
      inputFile = pkgs.writeText "fetch-tree-${name}-input.json" (
        builtins.toJSON (toFetchTreeInput cfg.input)
      );
      futureDir = ''"$STATE_DIR/fetch-tree/${name}"'';
    in
    lib.nameValuePair "fetch-tree-${name}" (
      pkgs.writeShellApplication {
        name = "fetch-tree-${name}";
        runtimeInputs = [ pkgs.nix ];
        text = ''
          mkdir -p ${futureDir}
          cd ${futureDir}
          nix-instantiate --eval --strict --json --expr "
            let tree = builtins.fetchTree (builtins.fromJSON (builtins.readFile ${inputFile}));
            in builtins.removeAttrs tree [\"outPath\"]
          " > result.json
        '';
      }
    )
  ) notReady;
}
