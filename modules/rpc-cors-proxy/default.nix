# Reverse proxy that injects CORS headers on top of a JSON-RPC upstream.
# Browser-side dApps (the Safe multisig UI, others) can't talk to public
# RPC endpoints directly because most fail CORS preflight; mount this
# at `<subdomain>.<apexDomain>` and point the wallet's chain config at it.
#
# Decoupled from the safe-multisig module. Importable on its own for
# any NixOS host that needs the same CORS dance.
{ config, lib, ... }:
let
  cfg = config.rpcCorsProxy;

  # Derive the upstream hostname from upstreamUrl for the Host header.
  # Strip scheme then take everything before the first `/` (handles
  # paths; bare host:port is left intact, which is what nginx wants).
  upstreamHost =
    let
      withoutScheme = lib.removePrefix "https://" (lib.removePrefix "http://" cfg.upstreamUrl);
    in
    lib.head (lib.splitString "/" withoutScheme);
in
{
  options.rpcCorsProxy = {
    enable = lib.mkEnableOption "CORS-injecting RPC reverse proxy";

    apexDomain = lib.mkOption {
      type = lib.types.str;
      example = "multisig.classix.dev";
      description = "Apex domain. The proxy mounts at `<subdomain>.<apexDomain>`.";
    };

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "rpc";
      description = "Subdomain to mount the proxy at.";
    };

    upstreamUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://rpc.classix.dev";
      description = ''
        Upstream RPC URL the proxy forwards to. The URL's hostname is
        extracted for the `Host` header so the upstream sees its own
        name (not the apex), which most RPC providers require.
      '';
    };

    tlsEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Issue Let's Encrypt certs for the proxy vhost via ACME.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.nginx.virtualHosts."${cfg.subdomain}.${cfg.apexDomain}" = {
      forceSSL = cfg.tlsEnabled;
      enableACME = cfg.tlsEnabled;

      # `proxy_pass` and `Host` live inside extraConfig (not as the
      # `proxyPass` option) on purpose. NixOS's `recommendedProxySettings`
      # appends `proxy_set_header Host $host` AFTER our extraConfig when
      # `proxyPass` is set, silently overriding the upstream hostname
      # we need. Writing them in extraConfig keeps our headers last-wins.
      locations."/".extraConfig = ''
        proxy_pass ${cfg.upstreamUrl};
        proxy_ssl_server_name on;
        proxy_http_version 1.1;
        proxy_set_header Host ${upstreamHost};
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        add_header Access-Control-Allow-Origin  "*"                  always;
        add_header Access-Control-Allow-Methods "POST, GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;

        if ($request_method = OPTIONS) {
          add_header Access-Control-Max-Age "86400" always;
          add_header Content-Length 0;
          add_header Content-Type   "text/plain";
          return 204;
        }
      '';
    };
  };
}
