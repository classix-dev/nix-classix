# nix-classix

Monorepo of Nix flakes for Classix infrastructure.

Today this is one flake. Future apps and platform modules will land
alongside the existing ones without restructuring.

## What's inside

| Output | What it is |
|---|---|
| `nixosModules.safe-multisig` | Self-hosted Safe multisig stack (upstream docker-compose project, Nix-built static UI, chain-bootstrap oneshot, host nginx). Brand-free, chain-mandatory. |
| `packages.safe-multisig-ui` | Standalone static export of `safe-global/safe-wallet-monorepo`. Vanilla build pointed at Safe's public gateway by default; consumers parameterise gateway / chain / branding. |
| `nixosModules.platform-digital-ocean` | DigitalOcean droplet bootstrap (cloud-init datasource, disko layout, bootloader, `mkForce` overrides for `digital-ocean-config.nix`). |
| `nixosModules.rpc-cors-proxy` | nginx location that injects CORS headers on top of a JSON-RPC upstream. Decoupled from `safe-multisig`; reusable. |
| `lib.chains.etc` | ETC chain preset function returning a `safeMultisig.chains.*` attrset. |
| `lib.brandPacks.classix` | Classix-specific branding pack (Michroma + Space Grotesk wordmark, ETC favicon, theme, footer link, notification banner). |
| `nixosModules.flavor-classix` | Turnkey composition: imports `safe-multisig` + `rpc-cors-proxy`, wires brand pack + ETC chain + theme + RPC upstream `https://rpc.classix.dev`. Platform-agnostic; consumer composes with a `platform-<provider>` module. |

## Consuming

The fastest path, a fully-wired Classix deploy on DigitalOcean:

```nix
# your-deploy/flake.nix
{
  inputs.nix-classix.url = "github:classix-dev/nix-classix";
  outputs = inputs@{ nixpkgs, ... }: {
    nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        inputs.nix-classix.inputs.disko.nixosModules.disko
        inputs.nix-classix.nixosModules.flavor-classix
        inputs.nix-classix.nixosModules.platform-digital-ocean
        {
          safeMultisig = {
            domain = "your-host.example.com";
            acmeEmail = "ops@example.com";
            timeZone = "UTC";
            sshAuthorizedKeys = [ "ssh-ed25519 AAAA..." ];
            tlsEnabled = true;
          };
        }
      ];
    };
  };
}
```

Pick individual pieces for a more custom build: import `safe-multisig`
+ a `platform-<provider>` module and wire chains / brand / RPC
yourself, or take `packages.safe-multisig-ui` alone for a static
frontend you host elsewhere.

## Lint

`nix run .#lint` runs nixfmt + statix + deadnix in fail-on-change mode.
The same checks run as a pre-commit hook on `git commit` (auto-installed
on dev-shell entry via `git-hooks.nix`) and in CI on every push (see
`.github/workflows/check.yml`).
