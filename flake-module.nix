# flake-parts module for nix-futures
{ flake-root }:
{ flake-parts-lib, ... }:
let
  inherit (flake-parts-lib) mkPerSystemOption;
in
{
  imports = [ flake-root.flakeModule ];

  options.perSystem = mkPerSystemOption (
    { config, lib, ... }:
    {
      imports = [ ./modules ];

      options.futures.relativeStateDir = lib.mkOption {
        type = lib.types.str;
        default = "_futures";
        description = "Relative path from flake root to state directory (used in poll scripts at runtime)";
      };

      config.futures.pollPrelude = ''
        FLAKE_ROOT="$(${lib.getExe config.flake-root.package})"
        STATE_DIR="$FLAKE_ROOT/${config.futures.relativeStateDir}"
        export FLAKE_ROOT STATE_DIR
      '';

      config.packages.futures-poll = config.futures.poll;
    }
  );
}
