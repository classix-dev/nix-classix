# Reverse-proxy nginx location that injects CORS headers on top of a
# JSON-RPC upstream. Browser-side dApps (the Safe multisig UI, others)
# can't talk to most public RPC endpoints directly because they fail
# CORS preflight; mount this at `<domain><path>` and point the wallet's
# chain config at it.
#
# Adds a `location` block to an existing nginx vhost (the consumer's
# apex). Avoids the extra DNS record / cert that a dedicated
# `rpc.<domain>` subdomain would need.
#
# Decoupled from the safe-multisig module. Importable on its own for
# any NixOS host whose nginx already serves `cfg.domain` and needs the
# same CORS dance.
{ config, lib, ... }:
let
  cfg = config.rpcCorsProxy;

  # Derive the upstream hostname from upstreamUrl for the `Host` header.
  # Strip scheme then take everything before the first `/`; bare host:port
  # is left intact, which is what nginx wants.
  upstreamHost =
    let
      withoutScheme = lib.removePrefix "https://" (lib.removePrefix "http://" cfg.upstreamUrl);
    in
    lib.head (lib.splitString "/" withoutScheme);
in
{
  options.rpcCorsProxy = {
    enable = lib.mkEnableOption "CORS-injecting RPC reverse proxy on an existing nginx vhost";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "multisig.classix.dev";
      description = ''
        Domain whose existing nginx vhost gets the proxy location added.
        The vhost must already exist (declared by another module or by
        the consumer); this module only adds the location block.
      '';
    };

    path = lib.mkOption {
      type = lib.types.str;
      default = "/rpc/";
      description = ''
        Location prefix on the vhost where the proxy is mounted.
        Trailing slash matters: nginx routes the prefix verbatim. The
        wallet's chain `rpcUri` should match: `https://<domain><path>`.
      '';
    };

    upstreamUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://rpc.classix.dev";
      description = ''
        Upstream RPC URL the proxy forwards to. Trailing slash matters;
        with a trailing slash, nginx strips the location prefix before
        forwarding (`/rpc/eth_call` becomes upstream `/eth_call`), which
        is what JSON-RPC endpoints at the root expect.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.nginx.virtualHosts.${cfg.domain}.locations.${cfg.path} = {
      # `proxy_pass` and `Host` live inside extraConfig (not as the
      # `proxyPass` option) on purpose. NixOS's `recommendedProxySettings`
      # appends `proxy_set_header Host $host` AFTER our extraConfig when
      # `proxyPass` is set, silently overriding the upstream hostname
      # we need. Writing them in extraConfig keeps our headers last-wins.
      extraConfig = ''
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
