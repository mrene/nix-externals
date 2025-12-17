{ lib }:
{
  # inputType: type of the input option (provider-specific)
  # valueType: type of the output value (optional, defaults to anything)
  # mkConfig: { name } -> { ready, value } - provider logic for resolution
  mkProvider =
    {
      inputType,
      valueType ? lib.types.anything,
      mkConfig,
    }:
    let
      futureSubmodule =
        { name, ... }:
        {
          options = {
            input = lib.mkOption { type = inputType; };
            ready = lib.mkOption {
              type = lib.types.bool;
              readOnly = true;
            };
            value = lib.mkOption {
              type = valueType;
              readOnly = true;
            };
          };
          config = mkConfig { inherit name; };
        };
    in
    lib.types.submodule {
      freeformType = lib.types.attrsOf (lib.types.submodule futureSubmodule);
      options.poll = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
      };
    };
}
