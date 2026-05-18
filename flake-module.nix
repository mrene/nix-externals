# flake-parts module for nix-externals
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

      options.externals.relativeStateDir = lib.mkOption {
        type = lib.types.str;
        default = "_externals";
        description = "Path relative to the flake root where state is materialized at runtime.";
      };

      config.externals.stateDir.runtimePath = /* bash */ ''
        "$(${lib.getExe config.flake-root.package})/${config.externals.relativeStateDir}"
      '';

      config.packages.externals-run = config.externals.run;
    }
  );
}
