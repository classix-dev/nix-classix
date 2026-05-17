# Reverse-proxy nginx location that injects CORS headers on top of a
# JSON-RPC upstream. Browser-side dApps (the Safe multisig UI, others)
# can't talk to most public RPC endpoints directly because they fail
# CORS preflight; mount this at `<domain>/rpc/` and point the wallet's
# chain config at it.
#
# Adds a `location` block to an existing nginx vhost (the consumer's
# apex). Avoids the extra DNS record / cert that a dedicated
# `rpc.<domain>` subdomain would need.
{ config, lib, ... }:
let
  cfg = config.rpcCorsProxy;

  # Normalise upstreamUrl to always end in `/`. Without it nginx
  # forwards `/rpc/<x>` to upstream `/rpc/<x>` (preserving the prefix)
  # instead of stripping `/rpc/` and sending `/<x>`. Most JSON-RPC
  # endpoints serve only at the root, so the un-stripped form 404s.
  upstreamWithSlash =
    if lib.hasSuffix "/" cfg.upstreamUrl then cfg.upstreamUrl else "${cfg.upstreamUrl}/";

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
        Domain whose existing nginx vhost gets the `/rpc/` location
        added. The vhost must already exist (declared by another module
        or by the consumer); this module only adds the location block.
      '';
    };

    upstreamUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://rpc.classix.dev";
      description = ''
        Upstream RPC URL the proxy forwards to. Trailing slash matters:
        with one, nginx strips the `/rpc/` prefix before forwarding
        (`/rpc/eth_call` becomes upstream `/eth_call`), which is what
        JSON-RPC endpoints at the root expect.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.nginx.virtualHosts.${cfg.domain}.locations."/rpc/" = {
      # `proxy_pass` and `Host` live inside extraConfig (not as the
      # `proxyPass` option) on purpose. NixOS's `recommendedProxySettings`
      # appends `proxy_set_header Host $host` AFTER our extraConfig when
      # `proxyPass` is set, silently overriding the upstream hostname
      # we need. Writing them in extraConfig keeps our headers last-wins.
      #
      # X-Real-IP, X-Forwarded-For, X-Forwarded-Proto are NOT set here;
      # `recommendedProxySettings` sets them at the http{} level.
      #
      # CORS headers are repeated inside the OPTIONS branch because
      # nginx does NOT inherit outer `add_header`s into an `if` block
      # that has its own `add_header`s. Without the repetition the
      # preflight 204 would lack `Access-Control-Allow-Origin` and the
      # browser would reject the actual request.
      extraConfig = ''
        client_max_body_size 10m;

        if ($request_method = OPTIONS) {
          add_header Access-Control-Allow-Origin  "*"                          always;
          add_header Access-Control-Allow-Methods "POST, GET, OPTIONS"         always;
          add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
          add_header Access-Control-Max-Age       "86400"                      always;
          add_header Content-Length 0;
          add_header Content-Type   "text/plain";
          return 204;
        }

        proxy_pass ${upstreamWithSlash};
        proxy_ssl_server_name on;
        proxy_http_version 1.1;
        proxy_set_header Host ${upstreamHost};

        add_header Access-Control-Allow-Origin  "*"                          always;
        add_header Access-Control-Allow-Methods "POST, GET, OPTIONS"         always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
      '';
    };
  };
}
