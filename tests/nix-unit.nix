let
  pkgs = import <nixpkgs> { };
  eval = pkgs.lib.evalModules {
    modules = [
      ../modules
      (
        { pkgs, ... }:
        {
          externals.stateDir = ./fixtures/_externals;
          externals.producers.custom = pkgs.writeShellApplication {
            name = "custom";
            text = "echo custom";
          };
          exec.ready-future.input = "true";
          exec.pending-future.input = "true";
        }
      )
    ];
    specialArgs = { inherit pkgs; };
  };
in
{
  # Direct registration: a producer assigned to externals.producers.<key> is preserved.
  testCustomProducerRegistered = {
    expr = eval.config.externals.producers ? custom;
    expected = true;
  };

  # Bare-path coercion: setting externals.stateDir to a path populates evalPath.
  testStateDirCoercion = {
    expr = builtins.isString (toString eval.config.externals.stateDir.evalPath);
    expected = true;
  };

  # runtimePath defaults to a shell-quoted form of evalPath when unset.
  testStateDirRuntimeDefault = {
    expr = builtins.isString eval.config.externals.stateDir.runtimePath;
    expected = true;
  };

  # exec provider - ready state (marker file exists)
  testExecReadyIsTrue = {
    expr = eval.config.exec.ready-future.ready;
    expected = true;
  };

  testExecReadyValueIsPath = {
    expr = builtins.isString (toString eval.config.exec.ready-future.value);
    expected = true;
  };

  # exec provider - not ready
  testExecPendingIsFalse = {
    expr = eval.config.exec.pending-future.ready;
    expected = false;
  };

  testExecPendingValueThrows = {
    expr = !(builtins.tryEval eval.config.exec.pending-future.value).success;
    expected = true;
  };

  # Aggregator is a derivation
  testExternalsPollIsDerivation = {
    expr = eval.config.externals.poll ? drvPath;
    expected = true;
  };

  # Provider only emits producer entries for not-ready exec entries.
  testProducerEmittedForPendingOnly = {
    expr =
      (eval.config.externals.producers ? "exec-pending-future")
      && !(eval.config.externals.producers ? "exec-ready-future");
    expected = true;
  };
}
