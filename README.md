# nix-docker-layered-image

Reusable helpers for building **semantically layered** Docker images
with `dockerTools.buildLayeredImage` (or `streamLayeredImage`), plus a
small Python tool to extract a built image's layer assignment so that
subsequent rebuilds preserve layer identity.

This was extracted from the [asm-tokenizer](https://github.com/sirati/asm-tokenizer)
project, where it was used to keep a ~3 GB layered image's blob cache
stable across nixpkgs bumps and per-package source changes.

## What's in here

- **`lib.semanticLayering.buildPipeline`** — turns a list of "units"
  (named groups of derivations / store paths) into a
  `layeringPipeline` value suitable for
  `pkgs.dockerTools.buildLayeredImage`'s `layeringPipeline` argument.
  Each unit becomes its own layer (or two layers, if `isolate = true`),
  in the order you list them. Whatever isn't claimed by any unit
  becomes a final "basics" tier.

  Useful when you want, e.g., your project source, your Rust wheel,
  Ghidra+JDK, and your Python deps each isolated in their own layer
  for cache-friendly rebuilds, instead of relying on the default
  popularity-contest algorithm (which can reshuffle on small input
  changes).

- **`lib.semanticLayering.readAssignmentFromEnv`** — reads a previous
  build's layer assignment from a JSON file path given by an env var,
  for use as `previousAssignment` to stabilise the basics tier across
  rebuilds. Requires `--impure`.

- **`packages.extract-layer-assignment`** — Python script that opens a
  `dockerTools.buildLayeredImage` output (a docker-archive `.tar.gz`)
  and dumps its layer-to-store-path assignment as JSON, in exactly the
  shape `buildPipeline { previousAssignment = …; }` consumes.

## Quickstart

Add this flake as an input:

```nix
{
  inputs.nix-docker-layered-image.url = "github:sirati/nix-docker-layered-image";
}
```

Then in your `outputs`:

```nix
let
  semanticLayering = inputs.nix-docker-layered-image.lib.${system}.semanticLayering;
in
pkgs.dockerTools.buildLayeredImage {
  name = "my-app";
  contents = [ pkgs.hello ];
  config.Cmd = [ "${pkgs.hello}/bin/hello" ];
  layeringPipeline = semanticLayering.buildPipeline {
    units = [
      { name = "app"; roots = [ pkgs.hello ]; isolate = true; }
      # …foundational units last…
    ];
    maxLayers = 120;
  };
}
```

A complete, buildable example lives in
[`examples/minimal-flake/`](examples/minimal-flake/flake.nix).

## Partial builds (cache-stable rebuilds)

After a successful build, dump the layer assignment and feed it back
on the next build:

```sh
nix build .#demo-image --print-out-paths \
  | xargs nix run github:sirati/nix-docker-layered-image#extract-layer-assignment -- \
  > .docker-layer-cache.json

NIX_DOCKER_LAYER_CACHE=$PWD/.docker-layer-cache.json \
  nix build .#demo-image --impure
```

The `tests/roundtrip.nix` expression exercises exactly this loop and
asserts that the resulting image hash is identical across the second
build.

## Contributor workflow

```sh
nix flake check                      # evaluates the flake's checks
nix run .#extract-layer-assignment   # CLI entry for the helper script
nix-build tests/roundtrip.nix        # standalone roundtrip test
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
