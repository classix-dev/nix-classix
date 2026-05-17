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
      appName = lib.mkDefault "ETC Safe Multisig";
      pack = classixBrandPack;
      theme = {
        textColor = "#ddffdc";
        backgroundColor = "#0a0a0a";
      };
    };
  };

  # Forwards `<deploy-domain>/rpc/` to the classix-operated upstream.
  # Wallet UI uses this via the chain's `rpcUri`. Deployments override
  # `upstreamUrl` to point at a different node, or disable the proxy
  # and set `chains.etc.rpcUri` directly at a CORS-friendly endpoint.
  rpcCorsProxy = {
    enable = true;
    domain = d;
    # ETC Cooperative's public CoreGeth node. Real ETC RPC (returns real
    # block heights, supports `eth_getLogs`, etc.) so the Safe Transaction
    # Service indexer can keep up. `rpc.classix.dev` is the
    # block-explorer-grade Clasico endpoint; it answers `eth_chainId`
    # but `eth_blockNumber` returns 0x0 and the indexer stalls.
    # Override per-deploy if Classix runs its own full node.
    upstreamUrl = lib.mkDefault "https://rpc.mainnet.etccooperative.org";
  };
}
