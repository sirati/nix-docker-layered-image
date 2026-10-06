# nix-docker-layered-image

Reusable helpers for building Docker images with semantic layers using
`dockerTools.buildLayeredImage` or `streamLayeredImage`. A small Python tool
extracts the layer assignment of a built image, so later rebuilds keep the
same layers.

This code comes from the [asm-tokenizer](https://github.com/sirati/asm-tokenizer)
project. There it kept the blob cache of a layered image of about 3 GB stable
across nixpkgs bumps and source changes in single packages.

## What's in here

- `lib.semanticLayering.buildPipeline` turns a list of "units" into a
  `layeringPipeline` value for the `layeringPipeline` argument of
  `pkgs.dockerTools.buildLayeredImage`. A unit is a named group of
  derivations or store paths. Each unit becomes its own layer, or two layers
  if `isolate = true`, in the order you list them. Everything that no unit
  claims goes into a final "basics" tier.

  Use it when you want separate layers for, for example, your project
  source, your Rust wheel, Ghidra+JDK and your Python dependencies, so
  rebuilds hit the cache. The default popularity-contest algorithm can
  reshuffle layers after small input changes.

- `lib.semanticLayering.readAssignmentFromEnv` reads the layer assignment
  of a previous build from a JSON file. An environment variable gives the
  file path. Pass the result as `previousAssignment` to keep the basics tier
  stable across rebuilds. It requires `--impure`.

- `packages.extract-layer-assignment` is a Python script. It opens the
  output of `dockerTools.buildLayeredImage`, a docker-archive `.tar.gz`, and
  writes its mapping from layers to store paths as JSON. The JSON has
  exactly the shape that `buildPipeline { previousAssignment = …; }` reads.

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

[`examples/minimal-flake/`](examples/minimal-flake/flake.nix) contains a
complete example that builds.

## Partial builds (cache-stable rebuilds)

After a successful build, write out the layer assignment and pass it to the
next build:

```sh
nix build .#demo-image --print-out-paths \
  | xargs nix run github:sirati/nix-docker-layered-image#extract-layer-assignment -- \
  > .docker-layer-cache.json

NIX_DOCKER_LAYER_CACHE=$PWD/.docker-layer-cache.json \
  nix build .#demo-image --impure
```

The `tests/roundtrip.nix` expression runs this loop and asserts that the
second build produces an identical image hash.

## Contributor workflow

```sh
nix flake check                      # evaluates the flake's checks
nix run .#extract-layer-assignment   # CLI entry for the helper script
nix-build tests/roundtrip.nix        # standalone roundtrip test
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
