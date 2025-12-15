let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  eval = lib.evalModules {
    modules = [
      ../../modules
      {
        futures.stateDir = ./_futures;
        futures.external.greeting.input = { };
        futures.external.pending.input = { };
      }
    ];
    specialArgs = { inherit pkgs; };
  };
in
{
  # Ready future (has _futures/external/greeting.nix)
  greeting = {
    inherit (eval.config.futures.external.greeting) ready value;
  };

  # Not ready future (no file exists)
  pending = {
    inherit (eval.config.futures.external.pending) ready;
    valueThrows = !(builtins.tryEval eval.config.futures.external.pending.value).success;
  };

  # Provider-level poll
  externalPoll = eval.config.futures.external.poll;

  # Top-level poll (aggregates all providers)
  poll = eval.config.futures.poll;
}
