{
  description = "Reusable Nix infrastructure for semantic docker-image layering (dockerTools.buildLayeredImage).";

  inputs = {
    # nixos-25.05 is the current stable channel. Consumers that need
    # a different nixpkgs can use the overlay directly against their
    # own pin (see overlays.default below).
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # ── pkgs-independent: the semantic-layering helpers only need
      # nixpkgs.lib (no derivations, no system). Exported per-system
      # below by re-importing with the system's lib so consumers get
      # a uniform `lib.${system}.semanticLayering` surface.
      semanticLayeringFor = pkgs: import ./lib/semantic-layering.nix { inherit (pkgs) lib; };

      # ── overlay: makes `extract-layer-assignment` available on
      # the consumer's pkgs, and exposes the semantic-layering
      # helpers under `pkgs.lib.semanticLayering` for ergonomic
      # `pkgs.lib.semanticLayering.buildPipeline { ... }` calls
      # without the consumer having to thread our flake's `lib`
      # output through their own module graph.
      overlay = final: prev: {
        extract-layer-assignment = final.callPackage ./pkgs/extract-layer-assignment { };
        lib = prev.lib // {
          semanticLayering = import ./lib/semantic-layering.nix { inherit (prev) lib; };
        };
      };
    in
    {
      overlays.default = overlay;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        # ── lib: the pure-nix helpers from lib/semantic-layering.nix.
        # Re-exported per-system so consumers that already have a
        # per-system pkgs handle can do
        #   inputs.nix-docker-layered-image.lib.${system}.semanticLayering.buildPipeline {...}
        # without juggling lib themselves.
        lib = {
          semanticLayering = semanticLayeringFor pkgs;
        };

        # ── packages: the extract-layer-assignment helper used to
        # dump a built image's layer assignment for partial-rebuild
        # cache stability (see lib/semantic-layering.nix's
        # `previousAssignment` arg + `readAssignmentFromEnv`).
        packages = {
          extract-layer-assignment = pkgs.callPackage ./pkgs/extract-layer-assignment { };
          default = self.packages.${system}.extract-layer-assignment;
        };

        # ── devShell: minimal shell for contributors iterating on
        # the flake itself (formatting, running the python script
        # against built images, etc.).
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.nix
            pkgs.python3
            pkgs.alejandra
          ];
        };

        # ── formatter: alejandra is the project formatter.
        formatter = pkgs.alejandra;
      }
    );
}
