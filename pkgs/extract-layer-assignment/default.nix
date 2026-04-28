{ lib
, stdenvNoCC
, python3
}:

# Tiny wrapper derivation around extract-layer-assignment.py.
#
# The script is pure-stdlib (json, sys, tarfile) and only uses
# PEP-585 generic syntax (`list[list[str]]`), so any Python >= 3.9
# is sufficient. We just need a stable interpreter on PATH and a
# correct shebang.

stdenvNoCC.mkDerivation {
  pname = "extract-layer-assignment";
  version = "0.1.0";

  src = ./.;

  # No build step; this is a single script.
  dontConfigure = true;
  dontBuild = true;

  # patchShebangs rewrites `#!/usr/bin/env python3` to the absolute
  # store path of this python3, so the script is self-contained
  # and does not depend on the user's PATH.
  nativeBuildInputs = [ python3 ];

  installPhase = ''
    runHook preInstall
    install -Dm755 extract-layer-assignment.py \
      "$out/bin/extract-layer-assignment"
    runHook postInstall
  '';

  postFixup = ''
    patchShebangs "$out/bin/extract-layer-assignment"
  '';

  meta = with lib; {
    description =
      "Extract layer-to-store-path assignment from a docker-archive tarball";
    longDescription = ''
      Reads a docker-archive (as produced by
      `dockerTools.streamLayeredImage` / `buildLayeredImage`) and
      emits a JSON list-of-lists of /nix/store paths per layer.
      The output is consumable as `previousAssignment` by
      semantic-layering.nix's buildPipeline, enabling stable
      layer assignment across rebuilds.
    '';
    mainProgram = "extract-layer-assignment";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
