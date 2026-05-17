# The classix flavor. Imports `safe-multisig` plus the DO platform
# module, then wires in the classix brand pack, the ETC chain preset,
# the classix theme colours, and the CORS-injecting `/rpc` virtual host
# that the chain's `rpcUri` points at.
#
# Consumer flake imports `nixosModules.flavors.classix` and sets the
# per-deploy identity (domain, acmeEmail, sshAuthorizedKeys, timeZone,
# tlsEnabled). Everything else is set here.
{
  config,
  lib,
  ...
}:
let
  cfg = config.safeMultisig;
  d = cfg.domain;
  tls = cfg.tlsEnabled;

  etcChain = import ../../lib/chains/etc.nix { domain = d; };
  classixBrandPack = import ../../packages/classix-brand-pack/default.nix { };

  etcUpstreamRpc = "https://rpc.mainnet.etccooperative.org";
in
{
  imports = [
    ../safe-multisig
    ../platforms/digital-ocean
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

  # CORS-injecting proxy for the ETC RPC. Wallet UI talks to
  # `https://rpc.<domain>` (set as the chain's rpcUri above); this
  # forwards to ETC Cooperative's public node and adds CORS headers so
  # the browser accepts the JSON-RPC replies. The upstream public RPC
  # fails browser CORS preflight if hit directly.
  #
  # `proxy_pass` lives inside extraConfig (not as the `proxyPass`
  # option) on purpose. NixOS appends `recommendedProxySettings`
  # (including `proxy_set_header Host $host`) AFTER our extraConfig
  # when `proxyPass` is set, silently overriding the upstream Host
  # header. Writing `proxy_pass` directly keeps our headers last-wins.
  services.nginx.virtualHosts."rpc.${d}" = {
    forceSSL = tls;
    enableACME = tls;
    locations."/".extraConfig = ''
      proxy_pass ${etcUpstreamRpc};
      proxy_ssl_server_name on;
      proxy_http_version 1.1;
      proxy_set_header Host rpc.mainnet.etccooperative.org;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;

      if ($request_method = OPTIONS) {
        add_header Access-Control-Allow-Origin  "*"      always;
        add_header Access-Control-Allow-Methods "POST, GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
        add_header Access-Control-Max-Age       "86400"  always;
        add_header Content-Length 0;
        add_header Content-Type   "text/plain";
        return 204;
      }

      add_header Access-Control-Allow-Origin  "*"      always;
      add_header Access-Control-Allow-Methods "POST, GET, OPTIONS" always;
      add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
    '';
  };
}
