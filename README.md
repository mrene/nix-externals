# nix-externals

Declare values that need external resolution next to the code that uses them.

A lot of work in Nix happens out of band. Dependency pins live in a separate `npins/` or `niv/` directory. Fixed-output derivation hashes get pasted in after a build fails. `gomod2nix.toml` and its .NET cousin have to be regenerated whenever inputs change. `nix2container` wants a fetched image manifest sitting next to your package. The recurring shape is the same: some value needs to be resolved by an external program, written somewhere, and then read back during evaluation — and the declaration of *what* to resolve typically lives far away from the code that consumes the result.

nix-externals is an evalModules module that gives this pattern a uniform shape. Each external is identified by a name; its `producer` is a script that writes `$STATE_DIR/<name>.nix`; the framework reports `ready` based on file presence and exposes `value = import "$STATE_DIR/<name>.nix"`. A single aggregator (`externals-poll`) walks every declared entry and runs each producer. The next evaluation picks up the materialized state.

This is an experiment. The implementation aims for the minimum needed to be useful; expect rough edges.

## Using it

`nix-externals` is an evalModules module first. The flake exposes both a flake-parts wrapper and the underlying module set, so it drops into anything evalModules already drives:

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

The first evaluation throws: `external 'fetch-tree-dotfiles' not ready. Run 'nix run .#externals-poll' to materialize.` Run it; `_externals/fetch-tree-dotfiles.nix` lands with the locked tree; evaluation succeeds; subsequent builds reuse the lock.

## How it works

Each external is a freeform entry under `externals.<name>` with three sub-options:

* `producer` — a `writeShellApplication` (or any package with a `mainProgram`) that, when run, writes `$STATE_DIR/<name>.nix`. Must be idempotent.
* `ready` — `builtins.pathExists "$STATE_DIR/<name>.nix"`. Cheap; safe to branch on with `lib.mkIf`.
* `value` — `import "$STATE_DIR/<name>.nix"` once ready; throws otherwise.

The aggregator at `externals.poll` (exposed as `packages.externals-poll` under flake-parts) runs every producer in turn. Each script is expected to no-op when its `<name>.nix` already exists.

## Examples

Two reference implementations live under `examples/`. They are *not* imported by default — pull them in explicitly when you want them.

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

### npins (`examples/npins.nix`)

Declare pins inline; the poller calls `npins add` for any entry missing from the existing `npins/` directory. The `npins` CLI stays the source of truth for updates — this example only fills in declared-but-missing pins. State lives in `npins/sources.json` (npins's own format), not under `$STATE_DIR`, so `ready`/`value` are computed off `npinsSources ? <name>` rather than the framework's file-presence convention.

```nix
imports = [ "${inputs.nix-externals}/examples/npins.nix" ];

npins.dir = ./npins;
npins.nixpkgs.input.github = {
  owner = "NixOS";
  repo = "nixpkgs";
  branch = "nixos-unstable";
};
```

## Rolling your own

If none of the examples fit, register a producer directly. The framework gives you `ready` and `value` for free:

```nix
externals.codegen.producer = pkgs.writeShellApplication {
  name = "codegen";
  text = ''
    out="$STATE_DIR/codegen.nix"
    if [ -e "$out" ]; then exit 0; fi
    # ... compute something ...
    echo '{ message = "hello"; }' > "$out"
  '';
};

# At your use site:
myValue = config.externals.codegen.value;   # { message = "hello"; }
```

For sidecar files (extracted archives, fetched keys), have the producer write its scratch state wherever it likes — only the `$STATE_DIR/<name>.nix` file is load-bearing for the framework. A common pattern is a sibling directory:

```nix
externals.assets.producer = pkgs.writeShellApplication {
  name = "assets";
  text = ''
    out="$STATE_DIR/assets.nix"
    if [ -e "$out" ]; then exit 0; fi
    mkdir -p "$STATE_DIR/assets.d"
    curl ... | tar xz -C "$STATE_DIR/assets.d"
    echo "./assets.d" > "$out"     # path resolves relative to assets.nix
  '';
};
```

## Related

- [clan vars](https://clan.lol/docs/25.11/guides/vars/vars-overview) — same general shape: vars are declared inside NixOS modules and materialized by `clan vars generate`. Clan is scoped to NixOS fleet management with first-class secret handling (sops, password-store); nix-externals is the underlying primitive.
- [npins](https://github.com/andir/npins) — pin manager with its own CLI; the example provider rides on top of it. The motivating difference is co-located declarations.
- [niv](https://github.com/nmattia/niv) — same shape as npins, predates it. Same separation-of-declaration tradeoff.
- Flake `inputs` — deterministic and well-understood, but fixed to the flake URL grammar and tied to `flake.lock`. nix-externals is intentionally not a flake-input mechanism.
- [dream2nix](https://github.com/nix-community/dream2nix) — much larger scope. nix-externals is closer to the lock-file primitive underneath.
