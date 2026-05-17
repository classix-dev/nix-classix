# The classix flavor. Imports `safe-multisig` plus `rpc-cors-proxy` and
# wires in the classix brand pack, the ETC chain preset, the classix
# theme colours, and the CORS-injecting `rpc.<domain>` upstream URL.
#
# Platform-agnostic. The consumer flake composes this with a
# `platforms.<provider>` module of choice (e.g. `platforms.digital-ocean`)
# plus per-deploy identity (domain, acmeEmail, sshAuthorizedKeys,
# timeZone, tlsEnabled).
{
  config,
  lib,
  ...
}:
let
  cfg = config.safeMultisig;
  d = cfg.domain;

  etcChain = import ../../lib/chains/etc.nix { domain = d; };
  classixBrandPack = import ../../packages/classix-brand-pack/default.nix { };
in
{
  imports = [
    ../safe-multisig
    ../rpc-cors-proxy
  ];

  safeMultisig = {
    hostName = lib.mkDefault "classix-multisig";
    primaryChain = "etc";
    chains.etc = etcChain;
    staticAssets = ../../packages/classix-brand-pack/assets;
    branding = {
      appName = lib.mkDefault "Classix Multisig";
      pack = classixBrandPack;
      theme = {
        textColor = "#ddffdc";
        backgroundColor = "#0a0a0a";
      };
    };
  };

  # Forward `<deploy-domain>/rpc/` to the classix-operated upstream.
  # Wallet UI talks to this via the chain's `rpcUri`. Deployments can:
  #   - override `upstreamUrl` to point at a different node (self-hosted
  #     ETC node, paid RPC provider, etc.);
  #   - disable the proxy (`rpcCorsProxy.enable = false`) and set the
  #     chain's `rpcUri` directly at a CORS-friendly endpoint.
  rpcCorsProxy = {
    enable = true;
    domain = d;
    upstreamUrl = lib.mkDefault "https://rpc.classix.dev";
  };
}
