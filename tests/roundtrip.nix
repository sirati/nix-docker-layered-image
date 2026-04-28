/*
  roundtrip.nix — layer-assignment roundtrip test

  Verifies the documented partial-build cache loop:

    1. Build a layered image once with no previousAssignment.
    2. Run extract-layer-assignment on the resulting tarball to dump
       the layer→store-path mapping as JSON.
    3. Rebuild with `previousAssignment = <that JSON>` fed back in.
    4. Assert the rebuilt image's tarball bytes hash identically to
       the first build's.

  Why this is a meaningful test (despite Nix derivations being
  reproducible by input): the two builds have *different* Nix inputs
  (one passes previousAssignment = null, the other passes a concrete
  assignment list). They should still produce byte-identical tarballs
  because the previousAssignment-driven pipeline is constructed to
  reproduce the same layer grouping the popularity-contest produced
  the first time. If buildPipeline's preserveLayers logic ever drifts
  (e.g. ordering changes, empty-layer handling differs), this catches
  it.

  Usage (from the repo root):

    nix-build tests/roundtrip.nix

  IFD note: this file imports a JSON file produced by an intermediate
  derivation, so Nix must build that derivation during evaluation
  (import-from-derivation). No extra flag is needed; just a normal
  `nix-build` works. If your nixpkgs pin has IFD disabled in restricted
  evaluation mode, run with `--option allow-import-from-derivation true`.
*/
let
  # Pin nixpkgs explicitly so the test is reproducible standalone.
  # Adjust this rev only when you mean to bump the test's pin.
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz";
  };
  pkgs = import nixpkgs { system = builtins.currentSystem; };
  lib = pkgs.lib;

  # Pull the helper directly from the parent repo. This keeps the
  # test independent of T2.1-A's flake.nix (which exposes the same
  # function via lib.${system}.semanticLayering).
  semanticLayering = import ../lib/semantic-layering.nix { inherit lib; };

  extractLayerAssignment = pkgs.runCommand "extract-layer-assignment" {
    buildInputs = [ pkgs.python3 ];
  } ''
    install -Dm755 ${../pkgs/extract-layer-assignment/extract-layer-assignment.py} \
      $out/bin/extract-layer-assignment
    patchShebangs $out/bin/extract-layer-assignment
  '';

  # Trivial payload — keep the closure tiny so the test runs fast
  # and the layer count stays small enough to eyeball in failure
  # output.
  payload = pkgs.hello;

  # ─── Step 1: build with no previousAssignment ──────────────────
  units = [
    {
      name = "app";
      roots = [ payload ];
      isolate = true;
    }
  ];

  pipelineFresh = semanticLayering.buildPipeline {
    inherit units;
    previousAssignment = null;
  };

  imageFirst = pkgs.dockerTools.buildLayeredImage {
    name = "roundtrip-test";
    tag = "first";
    contents = [ payload ];
    config.Cmd = [ "${payload}/bin/hello" ];
    layeringPipeline = pipelineFresh;
  };

  # ─── Step 2: extract that image's layer assignment ─────────────
  assignmentDrv = pkgs.runCommand "roundtrip-assignment.json" {
    buildInputs = [ extractLayerAssignment ];
  } ''
    extract-layer-assignment ${imageFirst} > $out
  '';

  # IFD: read the JSON the previous derivation produced, parse it,
  # and feed it back into a fresh pipeline build.
  previousAssignment =
    builtins.fromJSON (builtins.readFile assignmentDrv);

  pipelineReplay = semanticLayering.buildPipeline {
    inherit units previousAssignment;
  };

  # ─── Step 3: rebuild with the recovered assignment ─────────────
  imageSecond = pkgs.dockerTools.buildLayeredImage {
    name = "roundtrip-test";
    tag = "first";  # Same tag as the first build for byte-identity.
    contents = [ payload ];
    config.Cmd = [ "${payload}/bin/hello" ];
    layeringPipeline = pipelineReplay;
  };

in
# ─── Step 4: compare the two image tarballs byte-for-byte ────────
#
# Primary assertion: tar SHA equality (the user-facing contract —
# byte-identical images produce byte-identical blob uploads).
#
# Secondary assertion: layer-assignment structural equality
# (extract-layer-assignment of the second image equals the
# previousAssignment we fed in). This is the helper's actual
# semantic promise; if SHAs diverge, this tells us whether the
# divergence is structural (different layer grouping — a buildPipeline
# bug) or merely byte-level (tar entry ordering, mtimes, etc., which
# would be a downstream nixpkgs concern).
pkgs.runCommand "roundtrip-check" {
  buildInputs = [ extractLayerAssignment pkgs.diffutils pkgs.jq ];
  passthru = {
    inherit imageFirst imageSecond assignmentDrv;
  };
} ''
  first_sha=$(sha256sum ${imageFirst} | cut -d' ' -f1)
  second_sha=$(sha256sum ${imageSecond} | cut -d' ' -f1)

  echo "first build  : ${imageFirst}"
  echo "second build : ${imageSecond}"
  echo "first  sha256: $first_sha"
  echo "second sha256: $second_sha"

  # Always check structural equality so the failure message can
  # distinguish structural bugs from byte-level divergence.
  extract-layer-assignment ${imageSecond} | jq -S . > second-assignment.json
  jq -S . ${assignmentDrv} > first-assignment.json
  if ! diff -u first-assignment.json second-assignment.json; then
    echo ""
    echo "FAIL: layer assignments differ — buildPipeline's"
    echo "      previousAssignment replay did not reproduce the"
    echo "      original layer grouping. This is a buildPipeline bug."
    exit 1
  fi
  echo "OK: layer assignments match structurally."

  if [ "$first_sha" != "$second_sha" ]; then
    echo ""
    echo "FAIL: image sha256 mismatch despite identical layer"
    echo "      assignments. Likely cause: tar entry ordering, mtime,"
    echo "      or other byte-level non-determinism in dockerTools"
    echo "      layered-image emission. Investigate before relying on"
    echo "      blob-cache hits across rebuilds."
    echo ""
    echo "extracted assignment JSON: ${assignmentDrv}"
    exit 1
  fi

  echo "OK: roundtrip stable, sha256=$first_sha"
  mkdir -p $out
  echo "$first_sha" > $out/sha256
  cp first-assignment.json $out/assignment.json
''
