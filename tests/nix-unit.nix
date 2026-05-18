let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  eval = lib.evalModules {
    modules = [
      ../modules
      (
        { pkgs, ... }:
        {
          externals.stateDir = ./fixtures/_externals;
          externals.ready-thing.producer = pkgs.writeShellApplication {
            name = "ready-thing";
            text = "true";
          };
          externals.pending-thing.producer = pkgs.writeShellApplication {
            name = "pending-thing";
            text = "true";
          };
        }
      )
    ];
    specialArgs = { inherit pkgs; };
  };
in
{
  # Bare-path coercion populates evalPath from the assigned path.
  testStateDirCoercion = {
    expr = builtins.isString (toString eval.config.externals.stateDir.evalPath);
    expected = true;
  };

  # runtimePath defaults to a shell-quoted form of evalPath when unset.
  testStateDirRuntimeDefault = {
    expr = builtins.isString eval.config.externals.stateDir.runtimePath;
    expected = true;
  };

  # ready=true when the fixture <name>.nix exists.
  testReadyIsTrue = {
    expr = eval.config.externals.ready-thing.ready;
    expected = true;
  };

  # value imports the fixture file's contents.
  testValueImported = {
    expr = eval.config.externals.ready-thing.value;
    expected = {
      msg = "hello";
    };
  };

  # ready=false when the fixture is absent.
  testPendingIsFalse = {
    expr = eval.config.externals.pending-thing.ready;
    expected = false;
  };

  # Reading value on a not-ready external throws.
  testPendingValueThrows = {
    expr = !(builtins.tryEval eval.config.externals.pending-thing.value).success;
    expected = true;
  };

  # Aggregator is a derivation.
  testExternalsRunIsDerivation = {
    expr = eval.config.externals.run ? drvPath;
    expected = true;
  };

  # Producer registration via externals.<name>.producer is observable.
  testProducerRegistered = {
    expr = eval.config.externals ? ready-thing && eval.config.externals.ready-thing ? producer;
    expected = true;
  };

  # Aggregator skips ready entries: its script text references the pending
  # producer's outPath but not the ready one's.
  testRunFiltersReadyEntries = {
    expr =
      let
        runText = builtins.unsafeDiscardStringContext eval.config.externals.run.text;
        readyOut = builtins.unsafeDiscardStringContext eval.config.externals.ready-thing.producer.outPath;
        pendingOut = builtins.unsafeDiscardStringContext eval.config.externals.pending-thing.producer.outPath;
      in
      {
        excludesReady = !(lib.hasInfix readyOut runText);
        includesPending = lib.hasInfix pendingOut runText;
      };
    expected = {
      excludesReady = true;
      includesPending = true;
    };
  };
}
