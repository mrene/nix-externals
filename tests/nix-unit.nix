let
  pkgs = import <nixpkgs> { };
  eval = pkgs.lib.evalModules {
    modules = [
      ../modules
      {
        futures.stateDir = ./fixtures/_futures;
        futures.external.ready-future.input = { };
        futures.external.pending-future.input = { };
      }
    ];
    specialArgs = { inherit pkgs; };
  };
in
{
  # External provider - ready state
  testExternalReadyIsTrue = {
    expr = eval.config.futures.external.ready-future.ready;
    expected = true;
  };

  testExternalReadyValue = {
    expr = eval.config.futures.external.ready-future.value;
    expected = {
      message = "hello";
      count = 42;
    };
  };

  # External provider - not ready state
  testExternalPendingIsFalse = {
    expr = eval.config.futures.external.pending-future.ready;
    expected = false;
  };

  testExternalPendingValueThrows = {
    expr = !(builtins.tryEval eval.config.futures.external.pending-future.value).success;
    expected = true;
  };

  # Provider poll is a derivation
  testExternalPollIsDerivation = {
    expr = eval.config.futures.external.poll ? drvPath;
    expected = true;
  };

  # Top-level poll aggregates providers
  testFuturesPollIsDerivation = {
    expr = eval.config.futures.poll ? drvPath;
    expected = true;
  };
}
