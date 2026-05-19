# Producer factory for nix-externals entries that compute a fixed-output
# derivation's hash by building it and parsing the hash-mismatch error.
#
# Returns a callPackage-style function the externals aggregator resolves at
# build time. Ported from dream2nix's `computeFODHash`
# (modules/dream2nix/core/lock/default.nix in nix-community/dream2nix).
#
# Usage:
#
#   externals.cargo-vendor-hash = {
#     filename = "cargo-vendor-hash";
#     producer = nix-externals.lib.mkFodHashProducer { drv = myCargoFOD; };
#   };
#
#   # at the consumer:
#   config.externals.cargo-vendor-hash.stringValue   # "sha256-…"
{ drv }:
{
  python3,
  nix,
  writeText,
  lib,
}:
let
  # Drop string context so the wrapper drv doesn't pull the FOD's source closure
  # into its inputs — matches dream2nix's behaviour.
  drvPath = builtins.unsafeDiscardStringContext drv.drvPath;
  drvName = drv.name;

  script = writeText "compute-fod-hash-${drvName}.py" ''
    import codecs
    import json
    import os
    import re
    import subprocess
    import sys

    out_path = os.environ["OUT"]
    drv_path = "${drvPath}"
    nix_bin = "${lib.getExe' nix "nix"}"
    pattern = re.compile(
        r"error: hash mismatch in fixed-output derivation '.*${lib.escapeRegex drvName}.*':"
    )

    proc = subprocess.Popen(
        [nix_bin, "build", "-L", drv_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    for line in proc.stdout:
        line = line.strip()
        print(line)
        if pattern.match(line):
            specified = next(proc.stdout).strip().split(" ", 1)
            got = next(proc.stdout).strip().split(" ", 1)
            assert specified[0] == "specified:" and got[0] == "got:"
            with open(out_path, "w") as f:
                f.write(got[1].strip())
            sys.exit(0)
    proc.wait()
    if proc.returncode:
        print("Could not determine hash", file=sys.stderr)
        sys.exit(1)

    # Build succeeded — the drv already records the correct hash.
    show = subprocess.run(
        [nix_bin, "derivation", "show", drv_path],
        stdout=subprocess.PIPE,
        text=True,
        check=True,
    )
    raw = json.loads(show.stdout)[drv_path]["outputs"]["out"]["hash"]
    encoded = codecs.encode(codecs.decode(raw, "hex"), "base64").decode().strip()
    with open(out_path, "w") as f:
        f.write(f"sha256-{encoded}")
  '';
in
''
  ${lib.getExe python3} ${script}
''
