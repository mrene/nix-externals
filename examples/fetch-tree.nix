# fetch-tree example - resolves fetchTree inputs to locked source trees.
#
# Producer writes the locked input attrs as JSON to $STATE_DIR/fetch-tree-<name>.json.
# Framework exposes that JSON via `externals.fetch-tree-<name>.jsonValue`; this module
# wraps it in `builtins.fetchTree` and re-exports as `fetch-tree.<name>.value` for
# callers that prefer the per-provider namespace.
#
# Producers are declared in function form (`pkgs: shellSnippet`) so this module can be
# imported at flake-parts top level, where `pkgs` is not yet available — the aggregator
# applies `pkgs` when building the runner.
{
  lib,
  config,
  ...
}:
let
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
in
{
  imports = [ ./fetch-tree-options.nix ];

  config.externals = lib.mapAttrs' (
    name: cfg:
    lib.nameValuePair "fetch-tree-${name}" {
      inherit (cfg) cacheKey;
      filename = "fetch-tree-${name}.json";
      producer =
        pkgs:
        let
          inputFile = pkgs.writeText "fetch-tree-${name}-input.json" (
            builtins.toJSON (toFetchTreeInput cfg.input)
          );
        in
        ''
          ${lib.getExe' pkgs.nix "nix-instantiate"} --eval --strict --json --expr "
            let
              input = builtins.fromJSON (builtins.readFile ${inputFile});
              tree = builtins.fetchTree input;
              locked = { narHash = tree.narHash; }
                // (if tree ? rev then { rev = tree.rev; } else { });
            in input // locked
          " > "$OUT"
        '';
    }
  ) config.fetch-tree;
}
