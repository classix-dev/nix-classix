# Matrix-Discord relay appliance: a minimal Synapse homeserver whose
# only job is hosting the mautrix-discord appservice, plus the bridge
# itself and Caddy terminating TLS. Nobody registers accounts here and
# no clients connect. The bridge bot joins rooms on other homeservers
# (e.g. #ethereum-classic:matrix.org) over federation and relays them
# to Discord through webhooks, so Matrix users show up on Discord with
# their own names and avatars.
#
# Division of labour: Caddy owns the domain (ACME certs) and routes
# /_matrix and /.well-known/matrix to Synapse on loopback, plus
# /mautrix-discord (the avatar proxy Discord fetches webhook avatars
# from) to the bridge. Synapse advertises federation on 443 via
# serve_server_wellknown, so 80/443 are the only open ports and no
# separate 8448 listener exists. Postgres backs Synapse. The bridge
# keeps its default sqlite db, a single plumbed room does not need
# more.
#
# Secrets never touch the nix store. The appservice tokens are
# generated on first boot by the nixpkgs mautrix-discord registration
# unit, the avatar-proxy signing key by a oneshot below, and the
# Discord bot token is entered at runtime by an admin DMing the bridge
# bot (it lands in the bridge db). The deploy file carries the
# onboarding runbook.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.matrixDiscordRelay;

  synapsePort = 8008;
  bridgePort = 29334;

  # Outside the bridge's dataDir on purpose: StateDirectory manages
  # /var/lib/mautrix-discord ownership and this file is written by a
  # root oneshot before that user exists.
  envFile = "/var/lib/matrix-discord-relay/env";

  # Minimal static page for browsers landing on the domain root, so
  # the server explains itself instead of returning an empty response.
  # Brand assets come from the classix brand pack.
  indexHtml = pkgs.writeText "matrix-relay-index.html" ''
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${cfg.domain}</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='6' fill='%2312ff80'/></svg>">
    <style>
      @font-face { font-family: 'Michroma'; src: url('/fonts/Michroma-latin.woff2') format('woff2'); font-display: swap; }
      @font-face { font-family: 'Space Grotesk'; src: url('/fonts/SpaceGrotesk-latin.woff2') format('woff2'); font-weight: 400 700; font-display: swap; }
      :root { color-scheme: dark; }
      body { margin: 0; background: #000; color: #e6e6e6; font: 17px/1.6 'Space Grotesk', system-ui, sans-serif;
             min-height: 100vh; display: grid; place-items: center; }
      main { text-align: center; padding: 2rem; }
      h1 { font-family: Michroma, 'Space Grotesk', system-ui, sans-serif; font-size: 1.3rem; color: #12ff80;
           letter-spacing: .04em; margin: 0 0 .75rem; overflow-wrap: anywhere; }
      p { margin: .25rem 0; color: #9a9a9a; }
      a { color: #12ff80; }
    </style>
    </head>
    <body><main>
    <h1>${cfg.domain}</h1>
    <p>A Matrix to Discord relay.</p>
    <p>Run by <a href="https://classix.dev">classix.dev</a></p>
    </main></body></html>
  '';

  landingPage = pkgs.runCommand "matrix-relay-landing" { } ''
    mkdir -p $out/fonts
    cp ${../../packages/classix-brand-pack/fonts/Michroma-latin.woff2} $out/fonts/Michroma-latin.woff2
    cp ${../../packages/classix-brand-pack/fonts/SpaceGrotesk-latin.woff2} $out/fonts/SpaceGrotesk-latin.woff2
    cp ${indexHtml} $out/index.html
  '';
in
{
  options.matrixDiscordRelay = {
    enable = lib.mkEnableOption "Synapse + mautrix-discord relay appliance";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "matrix.classix.dev";
      description = ''
        Homeserver name. Becomes the server part of the bridge bot and
        ghost user IDs (@discord_...:domain). Federation bakes it into
        the history of every bridged room, so treat it as permanent.
      '';
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      example = "ops@classix.dev";
      description = "ACME registration email for Caddy.";
    };

    admins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "@ops:matrix.org" ];
      description = ''
        Matrix IDs with admin access to the bridge bot. Any homeserver
        works, admins DM the bot over federation. At least one is
        needed to log the Discord bot in and plumb rooms.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # mautrix-discord links libolm for end-to-bridge encryption, and
    # nixpkgs marks libolm insecure (side-channel CVEs, upstream
    # unmaintained). This relay only plumbs public unencrypted rooms,
    # so the encryption path never runs.
    nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

    services.postgresql = {
      enable = true;
      # Synapse refuses databases without C collation, so ensureDatabases
      # (which inherits the cluster default) is not enough.
      initialScript = pkgs.writeText "synapse-init.sql" ''
        CREATE ROLE "matrix-synapse" WITH LOGIN;
        CREATE DATABASE "matrix-synapse" WITH OWNER "matrix-synapse"
          TEMPLATE template0
          LC_COLLATE = "C"
          LC_CTYPE = "C";
      '';
    };

    services.matrix-synapse = {
      enable = true;
      settings = {
        server_name = cfg.domain;
        # Serves /.well-known/matrix/server pointing federation at
        # <domain>:443, which Caddy routes back here.
        serve_server_wellknown = true;
        enable_registration = false;

        database = {
          name = "psycopg2";
          # Peer auth over the local socket, the synapse unit runs as
          # the matrix-synapse user created above.
          args = {
            user = "matrix-synapse";
            database = "matrix-synapse";
          };
        };

        listeners = [
          {
            port = synapsePort;
            bind_addresses = [ "127.0.0.1" ];
            type = "http";
            tls = false;
            x_forwarded = true;
            resources = [
              {
                names = [
                  "client"
                  "federation"
                ];
                compress = true;
              }
            ];
          }
        ];
      };
    };

    services.mautrix-discord = {
      enable = true;
      registerToSynapse = true;
      environmentFile = envFile;
      serviceDependencies = [ "matrix-discord-relay-env.service" ];

      # The nixpkgs module declares each settings section (homeserver,
      # bridge, ...) as a leaf attrs option, so defining any key in a
      # section throws away that section's entire default (which holds
      # required values like username_template and command_prefix).
      # Layer our values over the declared defaults instead. Priority
      # wrappers (mkForce etc.) must not appear inside these attrsets,
      # the freeform yaml type serializes them literally.
      settings =
        let
          defaults =
            section: (options.services.mautrix-discord.settings.type.getSubOptions [ ]).${section}.default;
        in
        {
          homeserver = defaults "homeserver" // {
            address = "http://127.0.0.1:${toString synapsePort}";
            inherit (cfg) domain;
          };

          # The appservice section keeps the module defaults (loopback
          # registration endpoint, sqlite db, @discordbot bot user).
          # bridgePort above must match its default port.

          bridge = lib.recursiveUpdate (defaults "bridge") {
            # Webhook relaying needs a public https address Discord can
            # fetch per-message avatars from. Caddy routes the
            # /mautrix-discord path prefix to the bridge.
            public_address = "https://${cfg.domain}";
            # Substituted from envFile by the module's envsubst pass.
            avatar_proxy_key = "$AVATAR_PROXY_KEY";

            # Everyone federated gets relayed through the webhook, only
            # the listed admins can drive the bot.
            permissions = {
              "*" = "relay";
            }
            // lib.genAttrs cfg.admins (_: "admin");
          };
        };
    };

    # The avatar proxy key signs the avatar URLs handed to Discord so
    # the endpoint cannot be scraped. Generated once, kept out of the
    # nix store, substituted into the bridge config via environmentFile.
    systemd.services.matrix-discord-relay-env = {
      description = "Generate the mautrix-discord avatar proxy key";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        if [ ! -f ${envFile} ]; then
          mkdir -p ${dirOf envFile}
          printf 'AVATAR_PROXY_KEY=%s\n' \
            "$(${pkgs.coreutils}/bin/tr -dc A-Za-z0-9 < /dev/urandom | ${pkgs.coreutils}/bin/head -c 32)" \
            > ${envFile}
        fi
      '';
    };

    services.caddy = {
      enable = true;
      email = cfg.acmeEmail;
      # Caddy sorts same-directive matchers by path length, so the
      # bridge and well-known prefixes win over the /_matrix catch-all
      # regardless of order here. Anything outside the Matrix paths
      # falls through to the static landing page.
      virtualHosts.${cfg.domain}.extraConfig = ''
        encode gzip
        root * ${landingPage}
        reverse_proxy /mautrix-discord/* 127.0.0.1:${toString bridgePort}
        reverse_proxy /.well-known/matrix/* 127.0.0.1:${toString synapsePort}
        reverse_proxy /_matrix/* 127.0.0.1:${toString synapsePort}
        file_server
      '';
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
