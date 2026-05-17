# Plan: Multisig Layering for nix-classix

## What exists today

[classix-dev/nix-catacomb](https://github.com/classix-dev/nix-catacomb) is a Nix flake that deploys a self-hosted Safe multisig stack onto a single VM. It runs upstream `safe-global/safe-infrastructure`'s docker-compose project verbatim against a NixOS-managed Docker daemon, plus a Nix-built static UI (`pkgs/safe-wallet-web/`) served by the host nginx, plus an idempotent chain-bootstrap oneshot that seeds `safe-config-service`. Deployed via [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) with disk layout driven by [disko](https://github.com/nix-community/disko).

[classix-dev/catacomb-classix-dev](https://github.com/classix-dev/catacomb-classix-dev) is the per-deploy consumer flake for the live instance at [catacomb.classix.dev](https://catacomb.classix.dev). It pins the library, provides the DO-specific bootstrap (cloud-init datasource and `lib.mkForce` overrides for `digital-ocean-config.nix`), and sets the demo notification banner. The classix-flavored opinions (ETC chain config, branding pack, theme) come from library defaults today, not from this repo.

An open PR on nix-catacomb, [refactor/extract-branding-pack](https://github.com/classix-dev/nix-catacomb/tree/refactor/extract-branding-pack), strips three opinions the library used to ship. Branding is replaced by a generic `branding.pack` submodule (`{ patches, postPatch, extraEnv }`). The `chains.etc = {...}` default is dropped (chains become mandatory, plus a mandatory `primaryChain`). `hosts/catacomb/defaultConfig.nix` is removed in favour of upstream-derived defaults inlined in `options.nix`. After this lands, the library is brand-free, chain-agnostic, and default-free.

## Why restructure

Three problems land us in this plan.

The repo names embed product opinions that no longer fit. "catacomb" is our internal label for "Safe stack plus classix branding plus ETC defaults", and the brand-free PR dismantles exactly what made the name fit. Once the library no longer ships catacomb-the-flavor, calling it `nix-catacomb` mismatches the contents.

The DO hardware module is inlined in the consumer flake. Every new deploy on DO copies the same disko and cloud-init incantation. Every new deploy on another cloud invents its own without an example to follow. That code wants to be a reusable module.

There's no clean Nix flake for the Safe multisig frontend on its own. The derivation in [nix-catacomb/pkgs/safe-wallet-web/](https://github.com/classix-dev/nix-catacomb/tree/main/pkgs/safe-wallet-web) already takes `src`, `appName`, `gatewayUrl`, `defaultChainId`, `extraEnv` as parameters, but it's buried inside the deployment repo and not surfaced as a first-class output. Upstream `safe-global/safe-wallet-monorepo` doesn't ship a flake either. Exposing one fills a real upstream gap.

## Naming

No use of "wallet" in our own flake outputs, NixOS module names, package names, repo names, or doc copy. Use "multisig" or descriptive terms. Upstream references stay as upstream named them: `safe-global/safe-wallet-monorepo` is referenced as such, but the derivation that builds from it is `safe-multisig-ui` on our side. Option namespace is `safeMultisig.*`, not `safeWallet.*`.

## Layering

Six pieces in `nix-classix`.

`packages.safe-multisig-ui` plus `lib.mkSafeMultisigUi { gatewayUrl, chainId, appName, brandingPack ? null, ... }`. Standalone frontend build. The package is a vanilla build pointed at Safe's public gateway and mainnet by default; `nix build .#safe-multisig-ui` gives a static `out/` directory deployable to Cloudflare Pages, S3, or wherever. The lib helper is for consumers who need custom env or branding without rewriting the derivation. An optional `nixosModules.safe-multisig-ui` wraps the package with nginx and TLS termination for the "NixOS box serving the UI pointed at someone else's gateway" case. The brand-pack input lives at this layer because the patch is applied to the React source here.

`nixosModules.safe-multisig`. The full backend stack: the upstream docker-compose project, the chain-bootstrap oneshot, host nginx, chain-config seeding via the Django ORM. Brand-free, chain-mandatory. Calls `mkSafeMultisigUi` internally to build its UI. This is what [nix-catacomb/hosts/catacomb/](https://github.com/classix-dev/nix-catacomb/tree/main/hosts/catacomb) is today, minus the renamed option namespace.

`nixosModules.platform-<provider>`. Per-cloud bootstrap modules sourced from `modules/platforms/`. First entry is `platform-digital-ocean`: cloud-init datasource, `lib.mkForce` overrides for `digital-ocean-config.nix`, bootloader settings, and the disko fragment (single-disk BIOS, `/dev/vda`). Currently inlined in [catacomb-classix-dev/flake.nix](https://github.com/classix-dev/catacomb-classix-dev/blob/main/flake.nix). Future siblings (`platform-hetzner`, `platform-vultr`, `platform-aws`) take the same shape; each is self-contained and owns its own disko + cloud-init quirks. The `safe-multisig` module is platform-agnostic and does not import disko itself. Flake outputs use flat names because flake-parts auto-coerces nested `nixosModules.foo.bar` into a single coerced module.

`packages.classix-brand-pack`. Classix-specific brand assets (Michroma + Space Grotesk fonts, ETC logo, theme) plus the React/CSS patch. Sourced from the pre-PR [nix-catacomb/pkgs/catacomb-branding/](https://github.com/classix-dev/nix-catacomb/tree/main/pkgs/catacomb-branding) (which the open PR deletes). A third party writing their own brand pack uses the same shape.

`lib.chains.etc`. Attrset with the ETC chain definition: `chainId = 61`, RPC URI, block-explorer URL templates, native-currency metadata. Consumers spread it into `safe-multisig`'s `chains` option. Any new chain preset takes the same shape.

`nixosModules.rpc-cors-proxy`. A reusable nginx-location module that adds CORS headers on top of a JSON-RPC upstream. Adds a `location` block to an existing vhost (the consumer's apex), so no extra DNS record or cert beyond the apex is needed. Decoupled from `safe-multisig`. Used by the classix flavor to forward `<domain>/rpc/` to the classix-operated RPC endpoint; importable on its own by any dApp host that needs the same dance.

`nixosModules.flavor-classix`. The composition: imports `safe-multisig` and `rpc-cors-proxy`, wires `branding.pack` to the classix brand pack, sets `chains.etc` from `lib`, sets `primaryChain = "etc"`, sets the theme colours, and enables the RPC CORS proxy with `upstreamUrl = "https://rpc.classix.dev"` as the default. Platform-agnostic. The private `classix-deployments` repo composes this with a `platform-<provider>` module of choice and adds per-deploy identity (domain, ACME email, SSH keys, timezone, notification banner).

## Migration order

1. ~~Land [refactor/extract-branding-pack](https://github.com/classix-dev/nix-catacomb/tree/refactor/extract-branding-pack) on nix-catacomb.~~ Skipped. nix-catacomb stays frozen for the duration of the migration so the live deploy keeps working; we copy the PR-branch shape directly into nix-classix instead.
2. Seed `nix-classix/modules/safe-multisig/` from `nix-catacomb/hosts/catacomb/`. Rename the option namespace from `catacomb.*` to `safeMultisig.*` in one commit. Lift the `pkgs/safe-wallet-web` derivation up to `packages.safe-multisig-ui` at the flake root.
3. Add `nix-classix/modules/platforms/digital-ocean/` from the inlined block in `catacomb-classix-dev/flake.nix`. Move the disko fragment out of `safe-multisig` into the platform module; drop `safeMultisig.bootDevice` from the option surface (the platform module hardcodes `/dev/vda` for DO).
4. Add `nix-classix/packages/classix-brand-pack/` from the pre-PR `pkgs/catacomb-branding/` directory. Patch internals (env var names, CSS classes) retain the historical `CATACOMB` prefix for stability; renaming is a follow-up.
5. Add `nix-classix/lib/chains/etc.nix`: a function `{ domain }: { chainId = 61; ... }` returning the ETC chain attrset.
6. Add `nix-classix/modules/rpc-cors-proxy/` (generic CORS-injecting reverse proxy) and `nix-classix/modules/flavors/classix.nix` (composition: imports safe-multisig + rpc-cors-proxy, sets chains + branding + theme, defaults the RPC upstream to `rpc.classix.dev`). The flavor stays platform-agnostic; consumers compose with a `platforms.<provider>` module.
7. Create the private `classix-deployments` repo. Move per-deploy identity (domain, SSH keys, ACME email, notification banner) out of `catacomb-classix-dev` into it. Cut over the live deploy via a `nixos-rebuild switch` from the new flake.
8. Archive `nix-catacomb` and `catacomb-classix-dev`. Leave a README pointing at `nix-classix`.

## Out of scope

A vanilla Safe NixOS module below `safe-multisig` (without the compose and bootstrap glue). Most of the value of `safe-multisig` is the orchestration, so splitting it out for purity isn't worth the work today.

Multi-chain on the live deploy. The bundled compose project indexes one chain at a time; adding chains requires parallel `txs` indexer instances per chain. Tracked as a TODO on nix-catacomb today, not in scope for this restructure.

Other cloud providers' hardware modules. `nixosModules.do-hardware` ships at the start; others get added as we deploy to them.
