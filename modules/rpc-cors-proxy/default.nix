# Reverse-proxy nginx location that injects CORS headers on top of a
# JSON-RPC upstream. Browser-side dApps (the Safe multisig UI, others)
# can't talk to most public RPC endpoints directly because they fail
# CORS preflight; mount this at `<domain>/rpc/` and point the wallet's
# chain config at it.
#
# Adds a `location` block to an existing nginx vhost (the consumer's
# apex). Avoids the extra DNS record / cert that a dedicated
# `rpc.<domain>` subdomain would need.
#
# A dedicated `services.nginx.upstreams.<name>` block with `keepalive 16`
# keeps TLS sessions warm across JSON-RPC calls. On a wallet page that
# fires dozens of RPCs at load, this saves ~100-300 ms per call vs the
# default behaviour (fresh TCP + TLS handshake per request).
{ config, lib, ... }:
let
  cfg = config.rpcCorsProxy;
  upstreamName = "rpc-cors-proxy-upstream";

  upstreamScheme = if lib.hasPrefix "http://" cfg.upstreamUrl then "http" else "https";
  upstreamPort = if upstreamScheme == "https" then "443" else "80";

  # Hostname (and only the hostname; not scheme, not path) extracted
  # from upstreamUrl for SNI + Host header.
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
        Upstream RPC URL the proxy forwards to. The `/rpc/` prefix is
        stripped before forwarding so most JSON-RPC endpoints, which
        serve at `/`, receive the request unchanged.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.nginx.upstreams.${upstreamName} = {
      servers."${upstreamHost}:${upstreamPort}" = { };
      extraConfig = ''
        keepalive 16;
      '';
    };

    services.nginx.virtualHosts.${cfg.domain}.locations."/rpc/" = {
      # `proxy_pass` and `Host` live inside extraConfig (not as the
      # `proxyPass` option) on purpose. NixOS's `recommendedProxySettings`
      # appends `proxy_set_header Host $host` AFTER our extraConfig when
      # `proxyPass` is set, silently overriding the upstream hostname.
      #
      # X-Real-IP, X-Forwarded-For, X-Forwarded-Proto are NOT set here;
      # `recommendedProxySettings` sets them at the http{} level.
      #
      # `proxy_ssl_name` is needed because nginx defaults to the upstream
      # BLOCK NAME for SNI; we override to the actual upstream hostname.
      #
      # `Connection ""` clears the upstream's default `close` so the
      # keepalive connection pool retains connections across requests.
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

        proxy_pass ${upstreamScheme}://${upstreamName}/;
        proxy_ssl_server_name on;
        proxy_ssl_name ${upstreamHost};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host ${upstreamHost};

        add_header Access-Control-Allow-Origin  "*"                          always;
        add_header Access-Control-Allow-Methods "POST, GET, OPTIONS"         always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
      '';
    };
  };
}
