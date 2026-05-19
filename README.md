# nix-externals

Declare values that need external resolution next to the code that uses them.

A lot of work in Nix happens out of band. Dependency pins live in a separate `npins/` or `niv/` directory. Fixed-output derivation hashes get pasted in after a build fails. `gomod2nix.toml` and its .NET cousin have to be regenerated whenever inputs change. `nix2container` wants a fetched image manifest sitting next to your package. The recurring shape is the same: some value needs to be resolved by an external program, written somewhere, and then read back during evaluation — and the declaration of *what* to resolve typically lives far away from the code that consumes the result.

nix-externals is an evalModules module that gives this pattern a uniform shape. Each external is identified by a name; its `producer` is a shell snippet that writes a Nix expression to `$OUT`; the framework reads it back as `value` and reports `ready` based on file presence. A single aggregator (`externals-run`) walks every not-yet-ready entry and runs its producer. The next evaluation picks up the materialized state.

This is an experiment. The implementation aims for the minimum needed to be useful; expect rough edges.

## Using it

`nix-externals` is module system agnostic. It plugs into any evalModules-based system and has no external dependencies. The flake exposes both a flake-parts wrapper and the underlying module set.
```nix
# flake-parts
imports = [ inputs.nix-externals.flakeModule ];

# NixOS / home-manager — import the modules and set stateDir yourself
imports = [ "${inputs.nix-externals}/modules" ];
externals.stateDir = ./_externals;

# bare lib.evalModules — see tests/nix-unit.nix for a worked example
lib.evalModules {
  modules = [ "${nix-externals}/modules" { externals.stateDir = ./_externals; } ];
  specialArgs = { inherit pkgs; };
}
```

`externals.stateDir` accepts either a bare path or a submodule split into `evalPath` (used for `pathExists` checks during Nix evaluation) and `runtimePath` (a shell expression resolved at runtime to the writable state location). The flake-parts entry overrides `runtimePath` to use `flake-root`, so producers write into the live working tree rather than the store-staged source. Bare-path consumers don't need to think about this — the default `runtimePath` derives from `evalPath` directly.

## Example

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-externals.url = "github:mrene/nix-externals";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
    systems = [ "x86_64-linux" "aarch64-darwin" ];
    imports = [ inputs.nix-externals.flakeModule ];

    perSystem = { pkgs, config, ... }: {
      imports = [ "${inputs.nix-externals}/examples/fetch-tree.nix" ];

      externals.stateDir = ./_externals;

      fetch-tree.dotfiles.input = "github:mrene/dotfiles";

      packages.dotfiles = pkgs.runCommand "dotfiles" { } ''
        ln -s ${config.fetch-tree.dotfiles.value} $out
      '';
    };
  };
}
```

The first evaluation throws: `external 'fetch-tree-dotfiles' not ready. Run 'nix run .#externals-run' to materialize.` Run it; `_externals/fetch-tree-dotfiles.nix` lands with the locked tree; evaluation succeeds; subsequent builds reuse the lock.

## How it works

Each external is a freeform entry under `externals.<name>` with three sub-options:

* `producer` — a shell snippet that writes the resolved Nix expression to `$OUT`. The framework wraps it in `pkgs.writeShellApplication` (shellcheck included) and only invokes it when the external is not yet ready, so no self-skip is needed.
* `ready` — `builtins.pathExists "$STATE_DIR/<name>.nix"`. Cheap; safe to branch on with `lib.mkIf`.
* `value` — `import "$STATE_DIR/<name>.nix"` once ready; throws otherwise.

When the aggregator at `externals.run` (exposed as `packages.externals-run` under flake-parts) invokes a producer, it exports `$OUT` pointing at `$STATE_DIR/<name>.nix` and `$STATE_DIR` for sidecar files. Ready entries are skipped at evaluation time — the aggregator's script only references producers it actually needs to invoke.

## Examples

Reference implementations live under `examples/`. They are *not* imported by default — pull them in explicitly when you want them.

### fetch-tree (`examples/fetch-tree.nix`)

Resolves a flake-style URL or a structured `attrTag` into a locked source tree via `builtins.fetchTree`. The locked attributes (`narHash`, `rev`) are baked into the emitted `fetch-tree-<name>.nix` so subsequent evaluations call `fetchTree` with the lock applied.

```nix
imports = [ "${inputs.nix-externals}/examples/fetch-tree.nix" ];

fetch-tree.nixpkgs.input = "github:NixOS/nixpkgs/nixos-unstable";
fetch-tree.flake-root.input.github = {
  owner = "srid";
  repo = "flake-root";
};

# config.fetch-tree.nixpkgs.value is a source tree (has outPath)
```

## Rolling your own

A producer is a shell snippet. Write the resolved Nix expression to `$OUT`:

```nix
externals.codegen.producer = ''
  # ... compute something ...
  echo '{ message = "hello"; }' > "$OUT"
'';

# At your use site:
myValue = config.externals.codegen.value;   # { message = "hello"; }
```

For sidecar files (extracted archives, fetched keys), the producer writes its scratch state wherever it likes — only `$OUT` (which the framework points at `$STATE_DIR/<name>.nix`) is load-bearing. A common pattern is a sibling directory:

```nix
externals.assets.producer = ''
  mkdir -p "$STATE_DIR/assets.d"
  curl ... | tar xz -C "$STATE_DIR/assets.d"
  echo "./assets.d" > "$OUT"     # path resolves relative to assets.nix
'';
```

## Related

- [dream2nix](https://github.com/nix-community/dream2nix) and its lock module.
- [clan vars](https://clan.lol/docs/25.11/guides/vars/vars-overview) same general shape: vars are declared inside NixOS modules and materialized by `clan vars generate`.
