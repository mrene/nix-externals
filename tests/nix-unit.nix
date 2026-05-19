let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  eval = lib.evalModules {
    modules = [
      ../modules
      {
        externals.stateDir = ./fixtures/_externals;
        externals.ready-thing.producer = ''echo '{}' > "$OUT"'';
        externals.pending-thing.producer = ''echo '{}' > "$OUT"'';
        externals.keyed-match = {
          producer = ''echo '{}' > "$OUT"'';
          cacheKey = "v1";
        };
        externals.keyed-mismatch = {
          producer = ''echo '{}' > "$OUT"'';
          cacheKey = "v1";
        };
        externals.keyed-missing-sidecar = {
          producer = ''echo '{}' > "$OUT"'';
          cacheKey = "v1";
        };
      }
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

  # Producer is a plain shell snippet (string).
  testProducerIsString = {
    expr = builtins.isString eval.config.externals.ready-thing.producer;
    expected = true;
  };

  # Aggregator wraps each not-ready producer as a shellApplication with name=<key>,
  # so /bin/<key> appears in the run script for pending entries and not for ready ones.
  testRunFiltersReadyEntries = {
    expr =
      let
        runText = builtins.unsafeDiscardStringContext eval.config.externals.run.text;
      in
      {
        excludesReady = !(lib.hasInfix "/bin/ready-thing" runText);
        includesPending = lib.hasInfix "/bin/pending-thing" runText;
      };
    expected = {
      excludesReady = true;
      includesPending = true;
    };
  };

  # Aggregator exports OUT before each producer invocation.
  testRunExportsOut = {
    expr = lib.hasInfix "OUT=\"$STATE_DIR/pending-thing.nix\"" (
      builtins.unsafeDiscardStringContext eval.config.externals.run.text
    );
    expected = true;
  };

  # cacheKey matching the sidecar leaves ready=true.
  testCacheKeyMatchReady = {
    expr = eval.config.externals.keyed-match.ready;
    expected = true;
  };

  # cacheKey set but sidecar holds a different value flips ready=false.
  testCacheKeyMismatchNotReady = {
    expr = eval.config.externals.keyed-mismatch.ready;
    expected = false;
  };

  # cacheKey set but sidecar absent flips ready=false even if the value file exists.
  testCacheKeyMissingSidecarNotReady = {
    expr = eval.config.externals.keyed-missing-sidecar.ready;
    expected = false;
  };

  # Aggregator writes the cacheKey sidecar after a producer with cacheKey runs.
  testRunWritesCacheKeySidecar = {
    expr = lib.hasInfix "printf '%s' v1 > \"$STATE_DIR/keyed-mismatch.cacheKey\"" (
      builtins.unsafeDiscardStringContext eval.config.externals.run.text
    );
    expected = true;
  };

  # Aggregator removes any stale sidecar when cacheKey is null.
  testRunRemovesCacheKeySidecarWhenUnset = {
    expr = lib.hasInfix "rm -f \"$STATE_DIR/pending-thing.cacheKey\"" (
      builtins.unsafeDiscardStringContext eval.config.externals.run.text
    );
    expected = true;
  };
}
