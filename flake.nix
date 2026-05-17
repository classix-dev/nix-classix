{
  description = "Nix flake: self-hosted Safe multisig stack, hardware modules, brand packs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Pre-commit hooks declared in Nix; auto-installs on devShell entry and
    # also surfaces as a `nix flake check` so CI runs the same gate.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # Upstream Safe self-hosting orchestration (docker-compose, env files,
    # internal nginx config). We `docker compose up -d` against this verbatim
    # rather than re-implement the topology in Nix.
    safe-infrastructure = {
      url = "github:safe-global/safe-infrastructure";
      flake = false;
    };

    # Upstream Safe multisig frontend. Pinned to the same release tag as
    # the docker image (web-v1.88.0). Built statically (next export) by
    # `packages/safe-multisig-ui` and served directly from the host nginx.
    safe-wallet-monorepo = {
      url = "github:safe-global/safe-wallet-monorepo/web-v1.88.0";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks.flakeModule
      ];

      perSystem =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              statix.enable = true;
              deadnix.enable = true;
            };
          };

          # Single pre-commit hook that runs the whole treefmt pipeline
          # (nixfmt + statix + deadnix). Auto-installed by the devShell
          # `shellHook` below and re-run as a `nix flake check`.
          pre-commit.settings.hooks.treefmt = {
            enable = true;
            package = config.treefmt.build.wrapper;
          };

          # `nix build .#safe-multisig-ui` produces the static `out/`
          # directory served by the host nginx. Built with default
          # branding here; per-deploy values (domain, chain, appName) are
          # injected at module evaluation time via `pkgs.callPackage` in
          # `modules/safe-multisig/ui.nix`.
          packages.safe-multisig-ui = pkgs.callPackage ./packages/safe-multisig-ui {
            src = inputs.safe-wallet-monorepo;
          };

          # Treefmt's wrapper already runs nixfmt + statix + deadnix in
          # fail-on-change mode, and the pre-commit hook re-runs them on
          # commit. Standalone `statix` / `deadnix` derivations would
          # duplicate the work.
          checks = {
            inherit (config.treefmt.build) wrapper;
          };

          devShells.default = pkgs.mkShell {
            inherit (config.pre-commit.devShell) shellHook;
            packages = with pkgs; [
              nixos-anywhere
              inputs.disko.packages.${pkgs.system}.disko
              nixfmt
              statix
              deadnix
              nix-output-monitor
            ];
          };

          # `nix run .#lint` runs the same toolchain as `nix fmt` but in
          # CI / fail-on-change mode. Equivalent to `nix flake check` for
          # this repo's purposes; useful as a single-command pre-push gate.
          # NOTE: treefmt does write fixes to disk in this mode (the
          # convention for treefmt-managed projects); commit them or revert.
          apps.lint = {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "lint";
                text = ''
                  set -eu
                  ${lib.getExe config.treefmt.build.wrapper} --fail-on-change
                  echo "✓ lint passed"
                '';
              }
            );
          };
        };

      flake = {
        # Reusable data / functions consumers can call directly.
        # `lib.chains.<name>` returns an entry for `safeMultisig.chains`.
        # `lib.brandPacks.<name>` returns a `branding.pack` attrset.
        lib = {
          chains = {
            etc = import ./lib/chains/etc.nix;
          };
          brandPacks = {
            classix = import ./packages/classix-brand-pack/default.nix;
          };
        };

        # Idiomatic consumption: import `flavors.classix` for a fully
        # wired classix-on-DigitalOcean deploy and set per-deploy
        # identity, or import `safe-multisig` + `platforms.<provider>`
        # individually and wire chains/branding/RPC yourself.
        nixosModules =
          let
            withArgs = mod: _: {
              imports = [ mod ];
              _module.args = {
                inherit (inputs) safe-infrastructure;
                inherit (inputs) safe-wallet-monorepo;
              };
            };
            mkSafeMultisig = withArgs ./modules/safe-multisig;
            mkFlavorClassix = withArgs ./modules/flavors/classix.nix;
          in
          {
            safe-multisig = mkSafeMultisig;
            default = mkSafeMultisig;
            platforms.digital-ocean = ./modules/platforms/digital-ocean;
            rpc-cors-proxy = ./modules/rpc-cors-proxy;
            flavors.classix = mkFlavorClassix;
          };
      };
    };
}
