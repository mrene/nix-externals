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
    let
      inputFile = pkgs.writeText "fetch-tree-${name}-input.json" (
        builtins.toJSON (toFetchTreeInput cfg.input)
      );
    in
    lib.nameValuePair "fetch-tree-${name}" {
      producer = ''
        locked=$(${lib.getExe' pkgs.nix "nix-instantiate"} --eval --strict --json --expr "
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
