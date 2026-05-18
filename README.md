# nix-futures

Declare values that need external resolution next to the code that uses them.

A lot of work in Nix happens out of band. Dependency pins live in a separate `npins/` or `niv/` directory. Fixed-output derivation hashes get pasted in after a build fails. `gomod2nix.toml` and its .NET cousin have to be regenerated whenever inputs change. `nix2container` wants a fetched image manifest sitting next to your package. The recurring shape is the same: some value needs to be resolved by an external program, written somewhere, and then read back during evaluation — and the declaration of *what* to resolve typically lives far away from the code that consumes the result.

A *future* here is a typed value with a resolution state, declared as an option inside an evalModules tree. Reading `.value` while it is not ready aborts evaluation with instructions on how to resolve it. A single poll script walks every declared future across every provider and writes the resolved state to disk. The next evaluation picks it up.

This is an experiment. The implementation aims for the minimum needed to be useful; expect rough edges.

## Using it

`nix-futures` is an evalModules module first. The flake exposes both a flake-parts wrapper and the underlying module set, so it drops into anything evalModules already drives:

```nix
# flake-parts
imports = [ inputs.nix-futures.flakeModule ];

# NixOS / home-manager — import the modules and set stateDir yourself
imports = [ "${inputs.nix-futures}/modules" ];
futures.stateDir = ./_futures;

# bare lib.evalModules — see tests/external/default.nix for a worked example
lib.evalModules {
  modules = [ "${nix-futures}/modules" { futures.stateDir = ./_futures; } ];
  specialArgs = { inherit pkgs; };
}
```

The flake-parts module wires `stateDir` to the flake root via `flake-root` and exposes `packages.futures-poll`. Outside flake-parts you set `stateDir` (and, if you need it, `pollPrelude`) yourself.

## Example

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-futures.url = "github:mrene/nix-futures";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
    systems = [ "x86_64-linux" "aarch64-darwin" ];
    imports = [ inputs.nix-futures.flakeModule ];

    perSystem = { pkgs, config, ... }: {
      futures.fetch-tree.dotfiles.input = "github:mrene/dotfiles";

      packages.dotfiles = pkgs.runCommand "dotfiles" { } ''
        ln -s ${config.futures.fetch-tree.dotfiles.value} $out
      '';
    };
  };
}
```

The first evaluation throws: `Future 'dotfiles' not ready. Run 'nix run .#futures-poll' to fetch.` Run it; the locked tree lands under `_futures/exec/fetch-tree/dotfiles/result.json`; evaluation succeeds; subsequent builds reuse the lock.

## How it works

Each provider declares an option submodule under `futures.<provider>.<name>`. The submodule has an `input` (provider-specific), a read-only `ready : bool`, and a read-only `value`. Reading `.value` when `ready = false` throws; `ready` is safe to branch on, so you can gate dependent outputs with `lib.mkIf` if you want evaluation to keep going.

Each provider also exposes a `poll` derivation that knows how to resolve its own unresolved entries. `packages.futures-poll` concatenates every provider's poll script. State lives under `futures.stateDir` (`_futures/` by default in the flake-parts entry); the layout inside is per-provider.

## Built-in providers

### external

A passthrough: `.value` is whatever Nix expression sits at `$STATE_DIR/external/<name>.nix`. Useful for tests and for futures resolved by some out-of-band process you don't want to embed in Nix.

```nix
futures.external.greeting.input = { };
# Create _futures/external/greeting.nix with the resolved value.
```

### exec

Runs a shell snippet or derivation in a per-future working directory. Whatever it writes there becomes `.value` — a path. A `.ready` marker is touched on success.

```nix
futures.exec.codegen.input = ''
  echo '{ message = "hello"; }' > config.nix
'';
# import "${config.futures.exec.codegen.value}/config.nix"
```

### fetch-tree

Resolves a flake-style URL or a structured `attrTag` into a locked source tree via `builtins.fetchTree`. The lock (narHash, rev) is written once and reused on later evaluations. Implemented on top of `exec`.

```nix
futures.fetch-tree.nixpkgs.input = "github:NixOS/nixpkgs/nixos-unstable";
futures.fetch-tree.flake-root.input.github = {
  owner = "srid";
  repo = "flake-root";
};
```

### npins

Declare pins inline; the poller calls `npins add` for any entry missing from the existing `npins/` directory. The `npins` CLI stays the source of truth for updates — this provider only fills in declared-but-missing pins.

```nix
futures.npins.dir = ./npins;
futures.npins.nixpkgs.input.github = {
  owner = "NixOS";
  repo = "nixpkgs";
  branch = "nixos-unstable";
};
```

## Writing a provider

A provider is an evalModules module that defines `options.futures.<name>` using `lib.mkProvider`:

```nix
{ lib, config, pkgs, ... }:
let
  futures = import "${nix-futures}/lib" { inherit lib; };
in
{
  options.futures.hostkey = lib.mkOption {
    type = futures.mkProvider {
      inputType = lib.types.str;
      valueType = lib.types.str;
      mkConfig = { name }:
        let
          file = "${config.futures.stateDir}/hostkey/${name}";
          ready = builtins.pathExists file;
        in {
          inherit ready;
          value =
            if ready then builtins.readFile file
            else throw "hostkey '${name}' not ready";
        };
    };
    default = { };
  };

  config.futures.hostkey.poll = pkgs.writeShellScriptBin "poll-hostkey" ''
    # write missing files into $STATE_DIR/hostkey/<name>
  '';
}
```

`mkProvider` builds a submodule with `freeformType` so each user-declared entry under your provider gets `input` / `ready` / `value` automatically. The four shipped providers are the working references.

## Related

- [clan vars](https://clan.lol/docs/25.11/guides/vars/vars-overview) — same general shape: vars are declared inside NixOS modules and materialized by `clan vars generate`. Clan is scoped to NixOS fleet management with first-class secret handling (sops, password-store); nix-futures is the underlying primitive.
- [npins](https://github.com/andir/npins) — pin manager with its own CLI; nix-futures' `npins` provider rides on top of it. The motivating difference is co-located declarations.
- [niv](https://github.com/nmattia/niv) — same shape as npins, predates it. Same separation-of-declaration tradeoff.
- Flake `inputs` — deterministic and well-understood, but fixed to the flake URL grammar and tied to `flake.lock`. nix-futures is intentionally not a flake-input mechanism.
- [dream2nix](https://github.com/nix-community/dream2nix) — much larger scope. nix-futures is closer to the lock-file primitive underneath.
