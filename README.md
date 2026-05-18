# nix-externals

Declare values that need external resolution next to the code that uses them.

A lot of work in Nix happens out of band. Dependency pins live in a separate `npins/` or `niv/` directory. Fixed-output derivation hashes get pasted in after a build fails. `gomod2nix.toml` and its .NET cousin have to be regenerated whenever inputs change. `nix2container` wants a fetched image manifest sitting next to your package. The recurring shape is the same: some value needs to be resolved by an external program, written somewhere, and then read back during evaluation — and the declaration of *what* to resolve typically lives far away from the code that consumes the result.

nix-externals is an evalModules module that gives this pattern a uniform shape. A *provider* (`exec`, `fetch-tree`, `npins`) exposes a typed `<provider>.<name>.{input, ready, value}` option triple. Reading `.value` when `ready` is false aborts evaluation with a message pointing at the poll command. A single aggregator script (`externals-poll`) walks every declared entry across every provider and writes the resolved state to disk. The next evaluation picks it up.

Each provider is an ordinary NixOS module that emits its producer scripts into a shared registry (`externals.producers.<key>`). There's no framework indirection: a provider author writes a regular module that computes `ready`/`value` however it likes and registers a `writeShellApplication` for the materialization step.

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
      externals.stateDir = ./_externals;

      fetch-tree.dotfiles.input = "github:mrene/dotfiles";

      packages.dotfiles = pkgs.runCommand "dotfiles" { } ''
        ln -s ${config.fetch-tree.dotfiles.value} $out
      '';
    };
  };
}
```

The first evaluation throws: `fetch-tree 'dotfiles' not ready. Run 'nix run .#externals-poll' to fetch.` Run it; the locked tree lands under `_externals/fetch-tree/dotfiles/result.json`; evaluation succeeds; subsequent builds reuse the lock.

## How it works

Each provider exposes its own `<provider>.<name>.{input, ready, value}` option triple. Reading `.value` when `ready` is false throws; `ready` is cheap and independent of `.value`, so you can branch with `lib.mkIf <provider>.<name>.ready` to keep evaluation valid while resolution is pending.

For each entry that isn't yet ready, the provider registers a `writeShellApplication` under `externals.producers."<provider>-<name>"`. The `externals-poll` aggregator (exposed as `packages.externals-poll` under flake-parts) runs every registered producer in turn. Each producer is expected to be idempotent and to write its result under `$STATE_DIR` at runtime.

## Built-in providers

### exec

Runs a shell snippet or derivation in a per-entry working directory under `$STATE_DIR/exec/<name>/`. Whatever the script writes there becomes `.value` — a path. A `.ready` marker is touched on success.

```nix
exec.codegen.input = ''
  echo '{ message = "hello"; }' > config.nix
'';
# import "${config.exec.codegen.value}/config.nix"
```

### fetch-tree

Resolves a flake-style URL or a structured `attrTag` into a locked source tree via `builtins.fetchTree`. The lock (narHash, rev) is written once and reused on later evaluations.

```nix
fetch-tree.nixpkgs.input = "github:NixOS/nixpkgs/nixos-unstable";
fetch-tree.flake-root.input.github = {
  owner = "srid";
  repo = "flake-root";
};
```

### npins

Declare pins inline; the poller calls `npins add` for any entry missing from the existing `npins/` directory. The `npins` CLI stays the source of truth for updates — this provider only fills in declared-but-missing pins.

```nix
npins.dir = ./npins;
npins.nixpkgs.input.github = {
  owner = "NixOS";
  repo = "nixpkgs";
  branch = "nixos-unstable";
};
```

### Rolling your own

If none of the built-ins fit, register a producer script directly:

```nix
externals.producers.my-thing = pkgs.writeShellApplication {
  name = "my-thing";
  text = ''
    if [ -e "$STATE_DIR/my-thing/.ready" ]; then exit 0; fi
    mkdir -p "$STATE_DIR/my-thing"
    # ... do the work, write into $STATE_DIR/my-thing/, then:
    touch "$STATE_DIR/my-thing/.ready"
  '';
};

# At your use site:
myValue = if builtins.pathExists "${toString config.externals.stateDir.evalPath}/my-thing/.ready"
  then import "${toString config.externals.stateDir.evalPath}/my-thing/result.nix"
  else throw "my-thing not ready, run 'nix run .#externals-poll'";
```

## Writing a provider

A provider is an ordinary NixOS module. Define an option tree for typed declarations, compute `ready`/`value` from on-disk state, and emit a `writeShellApplication` per unresolved entry into `externals.producers.<key>`:

```nix
{ lib, config, pkgs, ... }:
let
  stateDir = "${toString config.externals.stateDir.evalPath}/hostkey";

  mkSubmodule = { name, ... }: let
    file = stateDir + "/${name}";
    ready = builtins.pathExists file;
  in {
    options = {
      input = lib.mkOption { type = lib.types.str; };
      ready = lib.mkOption { type = lib.types.bool; default = ready; };
      value = lib.mkOption {
        type = lib.types.str;
        default = if ready then builtins.readFile file
                  else throw "hostkey '${name}' not ready";
      };
    };
  };

  notReady = lib.filterAttrs (_: cfg: !cfg.ready) config.hostkey;
in {
  options.hostkey = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule mkSubmodule);
    default = { };
  };

  config.externals.producers = lib.mapAttrs' (name: cfg:
    lib.nameValuePair "hostkey-${name}" (pkgs.writeShellApplication {
      name = "hostkey-${name}";
      text = ''
        ssh-keyscan ${cfg.input} > "$STATE_DIR/hostkey/${name}"
      '';
    })
  ) notReady;
}
```

The three shipped providers (`exec`, `fetch-tree`, `npins`) are working references of varying complexity.

## Related

- [clan vars](https://clan.lol/docs/25.11/guides/vars/vars-overview) — same general shape: vars are declared inside NixOS modules and materialized by `clan vars generate`. Clan is scoped to NixOS fleet management with first-class secret handling (sops, password-store); nix-externals is the underlying primitive.
- [npins](https://github.com/andir/npins) — pin manager with its own CLI; nix-externals' `npins` provider rides on top of it. The motivating difference is co-located declarations.
- [niv](https://github.com/nmattia/niv) — same shape as npins, predates it. Same separation-of-declaration tradeoff.
- Flake `inputs` — deterministic and well-understood, but fixed to the flake URL grammar and tied to `flake.lock`. nix-externals is intentionally not a flake-input mechanism.
- [dream2nix](https://github.com/nix-community/dream2nix) — much larger scope. nix-externals is closer to the lock-file primitive underneath.
