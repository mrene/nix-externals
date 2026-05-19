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
        externals.string-thing.producer = ''echo 'hello' > "$OUT"'';
        externals.json-thing = {
          producer = ''echo '{}' > "$OUT"'';
          filename = "json-thing.json";
        };
        externals.custom-named = {
          producer = ''echo '{}' > "$OUT"'';
          filename = "deps.json";
        };
        externals.fn-form = {
          # callPackage-style producer: deps named in the attrset get pulled from pkgs.
          producer = { coreutils, lib, ... }: ''${lib.getExe' coreutils "echo"} '{}' > "$OUT"'';
        };
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

  # Data-only evaluation: no pkgs, no aggregator. Proves the read-side layer is
  # pure data and can be imported into top-level flake-parts trees.
  dataEval = lib.evalModules {
    modules = [
      ../modules/data.nix
      {
        externals.stateDir = ./fixtures/_externals;
        externals.ready-thing.producer = ''echo '{}' > "$OUT"'';
        externals.pending-thing.producer = ''echo '{}' > "$OUT"'';
      }
    ];
  };
in
{
  # Bare-path coercion populates evalPath from the assigned path.
  testStateDirCoercion = {
    expr = builtins.isString (toString eval.config.externals.stateDir.evalPath);
    expected = true;
  };

  # runtimePath defaults to a shell-quoted form of stateDir.evalPath when unset.
  testRuntimePathDefault = {
    expr = builtins.isString eval.config.externals.runtimePath;
    expected = true;
  };

  # ready=true when the fixture file exists.
  testReadyIsTrue = {
    expr = eval.config.externals.ready-thing.ready;
    expected = true;
  };

  # nixValue imports the fixture file's contents.
  testNixValue = {
    expr = eval.config.externals.ready-thing.nixValue;
    expected = {
      msg = "hello";
    };
  };

  # stringValue returns trimmed file contents.
  testStringValue = {
    expr = eval.config.externals.string-thing.stringValue;
    expected = "hello";
  };

  # jsonValue parses the fixture file as JSON.
  testJsonValue = {
    expr = eval.config.externals.json-thing.jsonValue;
    expected = {
      msg = "from-json";
      count = 42;
    };
  };

  # path is exposed even when the external is not ready.
  testPathAlwaysExposed = {
    expr = eval.config.externals.pending-thing.path;
    expected = toString ./fixtures/_externals + "/pending-thing";
  };

  # ready=false when the fixture is absent.
  testPendingIsFalse = {
    expr = eval.config.externals.pending-thing.ready;
    expected = false;
  };

  # Reading any decoder on a not-ready external throws.
  testPendingNixValueThrows = {
    expr = !(builtins.tryEval eval.config.externals.pending-thing.nixValue).success;
    expected = true;
  };

  testPendingStringValueThrows = {
    expr = !(builtins.tryEval eval.config.externals.pending-thing.stringValue).success;
    expected = true;
  };

  testPendingJsonValueThrows = {
    expr = !(builtins.tryEval eval.config.externals.pending-thing.jsonValue).success;
    expected = true;
  };

  # Aggregator is a derivation.
  testExternalsRunIsDerivation = {
    expr = eval.config.externals.run ? drvPath;
    expected = true;
  };

  # String-form producer is stored as-is.
  testProducerIsString = {
    expr = builtins.isString eval.config.externals.ready-thing.producer;
    expected = true;
  };

  # Function-form producer is stored as a function.
  testProducerIsFunction = {
    expr = builtins.isFunction eval.config.externals.fn-form.producer;
    expected = true;
  };

  # Aggregator resolves the function-form producer (otherwise wrapping the function
  # as `writeShellApplication.text` would error). The wrapper bin appears in the run
  # script alongside the other not-ready entries.
  testRunResolvesFunctionProducer = {
    expr = lib.hasInfix "/bin/fn-form" (
      builtins.unsafeDiscardStringContext eval.config.externals.run.text
    );
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

  # Aggregator exports OUT using the external's filename (default = name, no extension).
  testRunExportsOut = {
    expr = lib.hasInfix "OUT=\"$STATE_DIR/pending-thing\"" (
      builtins.unsafeDiscardStringContext eval.config.externals.run.text
    );
    expected = true;
  };

  # Custom filename flows through to the aggregator's $OUT export.
  testRunUsesCustomFilename = {
    expr = lib.hasInfix "OUT=\"$STATE_DIR/deps.json\"" (
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

  # Data layer alone (no pkgs) exposes the read-side accessors.
  testDataLayerReads = {
    expr = dataEval.config.externals.ready-thing.nixValue;
    expected = {
      msg = "hello";
    };
  };

  # Data layer alone does not declare `externals.run` — that lives in the aggregator
  # layer, which requires pkgs. This is what lets the data module live at the
  # flake-parts top level.
  testDataLayerHasNoRun = {
    expr = dataEval.config.externals ? run;
    expected = false;
  };

  # Data layer alone does not declare `runtimePath` either.
  testDataLayerHasNoRuntimePath = {
    expr = dataEval.config.externals ? runtimePath;
    expected = false;
  };
}
