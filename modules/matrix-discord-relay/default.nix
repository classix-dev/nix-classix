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

      settings = {
        homeserver = {
          address = "http://127.0.0.1:${toString synapsePort}";
          inherit (cfg) domain;
        };

        appservice = {
          address = "http://127.0.0.1:${toString bridgePort}";
          hostname = "127.0.0.1";
          port = bridgePort;
        };

        bridge = {
          # Webhook relaying needs a public https address Discord can
          # fetch per-message avatars from. Caddy routes the
          # /mautrix-discord path prefix to the bridge.
          public_address = "https://${cfg.domain}";
          # Substituted from envFile by the module's envsubst pass.
          avatar_proxy_key = "$AVATAR_PROXY_KEY";

          # Everyone federated gets relayed through the webhook, only
          # the listed admins can drive the bot. mkForce so no default
          # example entries survive the merge.
          permissions = lib.mkForce ({ "*" = "relay"; } // lib.genAttrs cfg.admins (_: "admin"));
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
      # regardless of order here.
      virtualHosts.${cfg.domain}.extraConfig = ''
        encode gzip
        reverse_proxy /mautrix-discord/* 127.0.0.1:${toString bridgePort}
        reverse_proxy /.well-known/matrix/* 127.0.0.1:${toString synapsePort}
        reverse_proxy /_matrix/* 127.0.0.1:${toString synapsePort}
      '';
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
