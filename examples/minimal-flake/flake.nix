{
  # ───────────────────────────────────────────────────────────────────
  #  minimal-flake — smallest viable consumer of nix-docker-layered-image
  #
  #  This example demonstrates the buildPipeline API end-to-end with a
  #  trivial payload (`pkgs.hello`) so the whole thing builds in
  #  seconds and has no heavyweight closure to inspect.
  #
  #  To exercise it from inside this repo:
  #
  #     cd examples/minimal-flake
  #     nix build .#demo-image
  #     # -> ./result is a docker-archive .tar.gz you can `docker load`
  #
  #  The relative path:../.. URL pins this example to the parent
  #  worktree's flake — handy for in-tree testing. A downstream
  #  consumer would instead use:
  #
  #     inputs.nix-docker-layered-image.url =
  #       "github:sirati/nix-docker-layered-image";
  # ───────────────────────────────────────────────────────────────────
  description = "Minimal nix-docker-layered-image consumer (hello-world image)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # In-tree relative path so this example tracks the worktree.
    # Downstream consumers replace this with a github:/ url.
    nix-docker-layered-image.url = "path:../..";
    nix-docker-layered-image.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, nix-docker-layered-image, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # The semantic-layering helpers, exposed by the parent flake at
      # `lib.${system}.semanticLayering`. Two functions live here:
      #
      #   buildPipeline { units, maxLayers ? 120, previousAssignment ? null }
      #     -> a value suitable for buildLayeredImage's
      #        `layeringPipeline` argument.
      #
      #   readAssignmentFromEnv "NIX_DOCKER_LAYER_CACHE"
      #     -> previous-build assignment as a list-of-list-of-paths,
      #        or null if the env var is unset / file missing.
      #        Requires `--impure` to read the env var.
      semanticLayering =
        nix-docker-layered-image.lib.${system}.semanticLayering;

      # Optional: read a cached layer assignment from disk so that a
      # rebuild reproduces the previous run's layer identities. Safe
      # to use unconditionally — returns null when the env var is
      # unset or the file is missing, in which case buildPipeline
      # falls back to the default popularity-contest basics tier.
      previousAssignment =
        semanticLayering.readAssignmentFromEnv "NIX_DOCKER_LAYER_CACHE";

      # The "units" list defines our semantic layers. Order is
      # MOST-SPECIFIC FIRST: each unit's closure is peeled out of the
      # remaining graph before subsequent units see it. Anything not
      # claimed by any unit lands in the implicit "basics" tier.
      #
      # `isolate = true` splits the unit's *explicit roots* into
      # their own layer, with their exclusive deps in a separate
      # popularity-contested layer. Use it for single leaves you
      # want guaranteed alone in a layer (project source, app
      # binaries you ship). Default `false` lumps the whole unit
      # closure into one popularity-contested layer set.
      units = [
        {
          name = "app";
          roots = [ pkgs.hello ];
          isolate = true;
        }
        # Foundational deps would go here, e.g.:
        # { name = "python-pkgs"; roots = [ pkgs.python3 ]; }
        # Anything not claimed becomes the basics tier automatically.
      ];

      pipeline = semanticLayering.buildPipeline {
        inherit units previousAssignment;
        maxLayers = 120;
      };
    in
    {
      packages.${system} = {
        # Trivial demo image — `docker load < result` then
        # `docker run hello:demo` prints "Hello, world!".
        demo-image = pkgs.dockerTools.buildLayeredImage {
          name = "hello";
          tag = "demo";
          contents = [ pkgs.hello ];
          config.Cmd = [ "${pkgs.hello}/bin/hello" ];
          layeringPipeline = pipeline;
        };

        # Re-export the helper script so users can dump the cache
        # without leaving the example dir:
        #   nix run .#extract-layer-assignment -- ./result > cache.json
        extract-layer-assignment =
          nix-docker-layered-image.packages.${system}.extract-layer-assignment;
      };
    };
}
