# Fetch-tree provider - resolves fetchTree hashes via impure evaluation
# Delegates to exec provider for actual execution
{
  lib,
  config,
  pkgs,
  ...
}:
let
  futures = import ../../lib { inherit lib; };

  # Structured input type: tagged union of fetchTree input types
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
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Tarball URL";
          };
        };
      };
    };
    file = lib.mkOption {
      type = lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "File URL";
          };
        };
      };
    };
    path = lib.mkOption {
      type = lib.types.submodule {
        options = {
          path = lib.mkOption {
            type = lib.types.path;
            description = "Local filesystem path";
          };
        };
      };
    };
  };

  # Combined input type: either a flake URL string or structured attrs
  # Examples:
  #   input = "github:NixOS/nixpkgs/ae2e6b3958682513d28f7d633734571fb18285dd"
  #   input.github = { owner = "NixOS"; repo = "nixpkgs"; }
  fetchTreeInputType = lib.types.either lib.types.str fetchTreeAttrsType;

  # Output type: Nix source tree (has outPath and can be used as a path)
  sourceTreeType = lib.mkOptionType {
    name = "sourceTree";
    description = "Nix source tree (result of builtins.fetchTree)";
    check = x: lib.isAttrs x && x ? outPath;
    merge = lib.mergeEqualOption;
  };

  # All fetch-tree futures (excluding poll)
  fetchTreeFutures = lib.filterAttrs (n: _: n != "poll") config.futures.fetch-tree;

  # Convert input to fetchTree attrs format
  # String: "github:owner/repo" -> { type = "github"; owner; repo; }
  # AttrTag: { github = { owner, repo, ... }; } -> { type = "github"; owner; repo; ... }
  toFetchTreeInput =
    input:
    if lib.isString input then
      builtins.parseFlakeRef input
    else
      let
        # attrTag sets exactly one attribute
        typeName = lib.head (lib.attrNames input);
        attrs = input.${typeName};
        # Filter out empty strings (defaults) and internal attrs
        cleanAttrs = lib.filterAttrs (n: v: v != "" && n != "_module") attrs;
      in
      cleanAttrs // { type = typeName; };

  # Create a fetch script for a given fetchTree input
  mkFetchScript =
    name: input:
    let
      inputFile = pkgs.writeText "fetch-${name}-input.json" (builtins.toJSON (toFetchTreeInput input));
    in
    pkgs.writeShellScriptBin "fetch-${name}" ''
      set -e
      nix-instantiate --eval --strict --json --expr "
        let tree = builtins.fetchTree (builtins.fromJSON (builtins.readFile ${inputFile}));
        in builtins.removeAttrs tree [\"outPath\"]
      " > result.json
    '';
in
{
  options.futures.fetch-tree = lib.mkOption {
    type = futures.mkProvider {
      inputType = fetchTreeInputType;
      valueType = sourceTreeType;
      mkConfig =
        { name }:
        let
          execFuture = config.futures.exec."fetch-tree/${name}";
          input = toFetchTreeInput config.futures.fetch-tree.${name}.input;
        in
        {
          ready = execFuture.ready;
          value =
            if execFuture.ready then
              let
                locked = builtins.fromJSON (builtins.readFile (execFuture.value + "/result.json"));
                # Only keep attrs needed for reproducible fetching
                lockedInput = lib.filterAttrs (
                  n: _:
                  builtins.elem n [
                    "narHash"
                    "rev"
                  ]
                ) locked;
              in
              builtins.fetchTree (input // lockedInput)
            else
              throw "Future '${name}' not ready. Run 'nix run .#futures-poll' to fetch.";
        };
    };
    default = { };
  };

  # Delegate to exec provider - create exec futures for each fetch-tree future
  config.futures.exec = lib.mapAttrs' (
    name: cfg: lib.nameValuePair "fetch-tree/${name}" { input = [ (mkFetchScript name cfg.input) ]; }
  ) fetchTreeFutures;

  # fetch-tree's poll is a no-op since exec handles it
  config.futures.fetch-tree.poll = pkgs.writeShellScript "poll-fetch-tree" ''
    echo "Fetch-tree provider:"
    echo "  (delegated to exec)"
  '';
}
