# nix-externals
Declare values that need external resolution next to the code that uses them.

## Why
A lot of work in Nix happens out of band. Dependency pins live in a separate `npins/` or `niv/` directory. Fixed-output derivation hashes get pasted in after a build fails. `gomod2nix.toml` and its .NET cousin have to be regenerated whenever inputs change. `nix2container` wants a fetched image manifest sitting next to your package. The recurring shape is the same: some value needs to be resolved by an external program, written somewhere, and then read back during evaluation — and the declaration of *what* to resolve typically lives far away from the code that consumes the result.


## How
nix-externals is an evalModules module that gives this pattern a uniform shape. Each external is identified by a name; its `producer` is a shell snippet that writes an artifact to `$OUT`; the framework exposes the resulting `path` and lazy decoders (`stringValue`, `jsonValue`, `nixValue`) for consumers to read it back. `ready` tracks file presence. A single aggregator (`externals-run`) walks every not-yet-ready entry and runs its producer. The next evaluation picks up the materialized state.

This is an experiment. The implementation aims for the minimum needed to be useful; expect rough edges.

## Using it

`nix-externals` is module system agnostic. It plugs into any evalModules-based system and has no external dependencies. The flake exposes both a flake-parts wrapper and the underlying module set.
```nix
# flake-parts — declarations and reads live at the top level; only the aggregator is per-system.
imports = [ inputs.nix-externals.flakeModule ];
externals.stateDir = ./_externals;
externals.foo.producer = ''…'';

# NixOS / home-manager — import the full module (data + aggregator).
imports = [ "${inputs.nix-externals}/modules" ];
externals.stateDir = ./_externals;

# bare lib.evalModules — see tests/nix-unit.nix for a worked example
lib.evalModules {
  modules = [ "${nix-externals}/modules" { externals.stateDir = ./_externals; } ];
  specialArgs = { inherit pkgs; };
}

# Read-only consumer (no pkgs needed) — import the pure data layer.
imports = [ "${inputs.nix-externals}/modules/data.nix" ];
```

`externals.stateDir` accepts either a bare path or a submodule with `evalPath` (used for `pathExists` checks during Nix evaluation). The runtime write location is exposed separately as `externals.runtimePath` — a shell expression evaluated by the aggregator. For non-flake-parts users it defaults to the escaped `evalPath`. For flake-parts users it's overridden to resolve via `flake-root`, so producers write into the live working tree rather than the store-staged source.

### Reading externals outside `perSystem`

In flake-parts, declarations live at the top level — so any non-`perSystem` output (`nixosConfigurations`, `flake.lib.*`, `flake.<anything>`) can read `config.externals.<name>.{path, ready, stringValue, jsonValue, nixValue}` directly. From inside `perSystem`, capture the outer `config` via closure:

```nix
outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (
  { config, ... }: {
    externals.versions.producer = ''…'';
    flake.lib.pinnedVersion = config.externals.versions.stringValue;

    perSystem = { pkgs, ... }: {
      packages.app = pkgs.runCommand "app" {} ''
        echo ${config.externals.versions.stringValue} > $out  # outer config
      '';
    };
  }
);
```

## Example

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-externals.url = "github:mrene/nix-externals";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (
    { config, ... }: {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      imports = [
        inputs.nix-externals.flakeModule
        "${inputs.nix-externals}/examples/fetch-tree.nix"
      ];

      externals.stateDir = ./_externals;
      fetch-tree.dotfiles.input = "github:mrene/dotfiles";

      perSystem = { pkgs, ... }: {
        packages.dotfiles = pkgs.runCommand "dotfiles" { } ''
          ln -s ${config.fetch-tree.dotfiles.value} $out
        '';
      };
    }
  );
}
```

The first evaluation throws: `external 'fetch-tree-dotfiles'.value not ready. Run 'nix run .#externals-run' to materialize.` Run it; `_externals/fetch-tree-dotfiles.json` lands with the locked input; evaluation succeeds; subsequent builds reuse the lock.

## How it works

Each external is a freeform entry under `externals.<name>` with these sub-options:

* `producer` — a shell snippet that writes the resolved artifact to `$OUT`. The framework wraps it in `pkgs.writeShellApplication` (shellcheck included) and only invokes it when the external is not yet ready, so no self-skip is needed.
* `filename` (optional) — basename of the artifact under `stateDir`. Defaults to the external's name with no extension. Override for ecosystem conventions (`deps.nix`, `lock.json`, etc.).
* `cacheKey` (optional) — a string the framework persists to `$STATE_DIR/<name>.cacheKey` after a successful run and re-checks on every evaluation. Mismatch (or missing sidecar) flips `ready` back to false. `null` (default) disables the check.
* `path` — absolute path to `$STATE_DIR/<filename>`. Always populated, regardless of `ready`. Use this when the consumer wants to read the file itself (e.g. `import path { … }` for a function-valued artifact, or pass it as `src` to a derivation).
* `ready` — true iff `path` exists and, when `cacheKey` is set, the sidecar matches it. Cheap; safe to branch on with `lib.mkIf`.
* `stringValue` — file contents as a string, trailing newline trimmed. Throws when not ready.
* `jsonValue` — `builtins.fromJSON` of the file. Throws when not ready.
* `nixValue` — `import` of the file. Throws when not ready.

The three decoders are lazy — only the one a consumer touches is evaluated, so a producer that emits raw text never pays JSON-parse cost.

When the aggregator at `externals.run` (exposed as `packages.externals-run` under flake-parts) invokes a producer, it exports `$OUT` pointing at `$STATE_DIR/<filename>` and `$STATE_DIR` for sidecar files. Ready entries are skipped at evaluation time — the aggregator's script only references producers it actually needs to invoke.

## Cache-busting

Set `externals.<name>.cacheKey` to any string you'd like to invalidate on. Bumping it forces the next `nix run .#externals-run` to re-invoke the producer:

```nix
externals.codegen.cacheKey = "2026-05-18";   # bump to force re-materialization
```

There's no auto-derivation from inputs — the string is whatever you want it to be (a version, a date, a hash of upstream metadata you fetched separately). Clearing it back to `null` removes any stale `<name>.cacheKey` sidecar on the next run.

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

`fetch-tree.<name>.cacheKey` is forwarded to the underlying external — bump it to force a re-lock without touching `input`.

## Rolling your own

A producer is a shell snippet. Write the resolved artifact to `$OUT` and pick the decoder that matches the format you wrote.

JSON (the most common case — `jq`, `curl`, `nix eval --json`, and most CLIs speak it natively):

```nix
externals.versions = {
  filename = "versions.json";
  producer = ''
    curl -fsSL https://example.com/versions.json > "$OUT"
  '';
};

# At your use site:
config.externals.versions.jsonValue   # { foo = "1.2.3"; bar = "4.5"; }
```

Plain string (single value — a version, a hash, a date):

```nix
externals.latest-tag.producer = ''
  git ls-remote --tags https://example.com/repo.git | tail -1 | cut -f2 > "$OUT"
'';

config.externals.latest-tag.stringValue   # "v1.2.3"
```

Nix expression (when the artifact is generated by something that already emits Nix):

```nix
externals.codegen.producer = ''
  generate-bindings > "$OUT"   # writes `{ message = "hello"; }`
'';

config.externals.codegen.nixValue   # { message = "hello"; }
```

### Producers that reference `pkgs`

When a producer needs to interpolate store paths or call tools by their package, declare it in nixpkgs-style attrset form. The aggregator resolves it via `pkgs.callPackage`, so dependencies are pulled from `pkgs` by name — just like a regular nixpkgs derivation:

```nix
externals.versions.producer = { curl, lib, ... }: ''
  ${lib.getExe curl} -fsSL https://example.com/versions.json > "$OUT"
'';
```

This works at the flake-parts top level (where `pkgs` isn't yet in scope), since the function is only evaluated when the aggregator builds. The plain-string form (`producer = "…"`) and the attrset-function form are interchangeable; use the function form whenever you need anything from `pkgs`.

### Just need a path

For artifacts that the consumer reads itself — a function-valued `deps.nix`, a sidecar to pass as `src`, a directory of fetched assets — use `path` directly. The `.NET fetch-deps` pattern is the canonical case:

```nix
externals.dotnet-deps = {
  filename = "deps.nix";
  producer = ''
    ${pkgs.dotnetCorePackages.sdk_8_0}/bin/dotnet \
      ${./fetch-deps.sh} "$OUT"
  '';
};

# At the use site (deps.nix is a function `{ fetchNuGet }: [ … ]`):
nugetDeps = import config.externals.dotnet-deps.path { inherit fetchNuGet; };
```

For sidecar files (extracted archives, fetched keys), the producer writes its scratch state wherever it likes — only `$OUT` (which the framework points at `$STATE_DIR/<filename>`) is load-bearing. A common pattern is a sibling directory:

```nix
externals.assets.producer = ''
  mkdir -p "$STATE_DIR/assets.d"
  curl ... | tar xz -C "$STATE_DIR/assets.d"
  echo "./assets.d" > "$OUT"     # the consumer reads stringValue + joins with path
'';
```

## Related

- [dream2nix](https://github.com/nix-community/dream2nix) and its lock module.
- [clan vars](https://clan.lol/docs/25.11/guides/vars/vars-overview) same general shape: vars are declared inside NixOS modules and materialized by `clan vars generate`.
