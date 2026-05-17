# Pre-built static UI (safe-wallet-monorepo `next export`) served from
# the host nginx. Replaces the upstream `ui:` docker container that
# ran `next build` at boot. Derivation lives at
# `packages/safe-multisig-ui`.
#
# Source-tree branding is opt-in via `safeMultisig.branding.pack`. When
# set, the upstream monorepo source is patched (`pack.patches`), files
# are dropped in (`pack.postPatch`), and extra `NEXT_PUBLIC_*` env vars
# (`pack.extraEnv`) are passed to `next build`. When null, vanilla Safe
# is built with only `branding.appName` swapped via the
# upstream-supported `NEXT_PUBLIC_BRAND_NAME`.
#
# Branding, gateway URL, and chain id are baked into the bundle at Nix
# eval time, so any change to `config.safeMultisig.branding`,
# `config.safeMultisig.domain`, or the primary chain's id triggers a
# full UI rebuild (~5-10 min). Pin to a binary cache that has the
# bundle to skip the rebuild on consumers.
{
  config,
  lib,
  pkgs,
  safe-wallet-monorepo,
  ...
}:
let
  cfg = config.safeMultisig;
  d = cfg.domain;
  tls = cfg.tlsEnabled;
  scheme = if tls then "https" else "http";

  brandedSrc =
    if cfg.branding.pack != null then
      pkgs.applyPatches {
        name = "safe-wallet-monorepo-branded";
        src = safe-wallet-monorepo;
        inherit (cfg.branding.pack) patches postPatch;
      }
    else
      safe-wallet-monorepo;

  ui = pkgs.callPackage ../../packages/safe-multisig-ui {
    src = brandedSrc;
    inherit (cfg.branding) appName;
    gatewayUrl = "${scheme}://${d}/cgw";
    defaultChainId = cfg.chains.${cfg.primaryChain}.chainId;
    isProduction = true;

    # Build-time env vars from the branding pack are only meaningful when
    # the pack is non-null (the patches that read them are only applied
    # then). Empty `{}` for a vanilla build.
    extraEnv = lib.optionalAttrs (cfg.branding.pack != null) cfg.branding.pack.extraEnv;
  };
in
{
  services.nginx.virtualHosts."${d}" = {
    # Static UI at the apex. `try_files` first looks for an exact match,
    # then a `.html` extension (next-export emits `/foo.html`, not
    # `/foo/index.html`), then falls back to the SPA shell.
    locations."/" = {
      root = "${ui}";
      tryFiles = "$uri $uri.html $uri/ /index.html";
    };

    # Consumer-supplied static assets at /assets/. Used for chain logos
    # (referenced by `chains.<name>.{nativeCurrency.logoUri, chainLogoUri}`)
    # and any other static file the consumer wants to serve at that
    # prefix. Dropped entirely when `staticAssets` is null.
    locations."/assets/" = lib.mkIf (cfg.staticAssets != null) {
      alias = "${cfg.staticAssets}/";
      extraConfig = ''
        add_header Cache-Control "public, max-age=86400";
      '';
    };

    # Path fanout to the still-containerised backends. The internal nginx
    # in the upstream compose stack already routes these on :8000. We
    # pass through a single proxy hop rather than re-implement the rules
    # here; that nginx has gzip, websocket forwarding, and
    # service-specific timeouts dialled in.
    #
    # The `/cgw/` extraConfig also rewrites cfg-service's broken
    # MEDIA_URL prefix on chain-logo URLs. CGW serializes them with
    # `http://localhost:8000/cfg/media/<the-url>` baked in (Mixed
    # Content + broken on the public host); whatever absolute URL is
    # configured for the chain logo, cfg-service mangles it into
    # `http://localhost:8000/cfg/media/https%3A/<rest>` (Django
    # collapses `//` to `/` and URL-encodes the colon). Rewrite both
    # the single- and double-encoded forms back to `https://<rest>`
    # before the JSON reaches the browser. Targets JSON responses only;
    # `sub_filter` works because the rewrite is a literal substring
    # (no JSON escaping involved for slashes/colons in this URL).
    locations."/cgw/" = {
      proxyPass = "http://127.0.0.1:8000";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Accept-Encoding "";
        sub_filter_once off;
        sub_filter_types application/json;
        sub_filter 'http://localhost:8000/cfg/media/https%3A/'   'https://';
        sub_filter 'http://localhost:8000/cfg/media/https%253A/' 'https://';
      '';
    };
    locations."/cfg/" = {
      proxyPass = "http://127.0.0.1:8000";
    };
    locations."/txs/" = {
      proxyPass = "http://127.0.0.1:8000";
    };
    locations."/events/" = {
      proxyPass = "http://127.0.0.1:8000";
      proxyWebsockets = true;
    };
  };

  # Expose the built UI path to systemd / debug tooling.
  environment.etc."safe-multisig/ui-path".text = "${ui}";
}
