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
  # Fonts come from the classix brand pack, colors from the classix.dev
  # navbar (#212525 pill, #ddffdc pale text, #a8f0a0 accent). Discord
  # and Matrix marks are the simple-icons paths, the gem is the ETC
  # logo from the brand pack recolored to the accent.
  indexHtml = pkgs.writeText "matrix-relay-index.html" ''
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${cfg.domain}</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='6' fill='%23a8f0a0'/></svg>">
    <style>
      @font-face { font-family: 'Michroma'; src: url('/fonts/Michroma-latin.woff2') format('woff2'); font-display: swap; }
      @font-face { font-family: 'Space Grotesk'; src: url('/fonts/SpaceGrotesk-latin.woff2') format('woff2'); font-weight: 400 700; font-display: swap; }
      :root { color-scheme: dark; }
      body { margin: 0; background: #000; color: #ddffdc; font: 17px/1.6 'Space Grotesk', system-ui, sans-serif;
             min-height: 100vh; display: grid; place-items: center; }
      main { text-align: center; padding: 2rem; }
      h1 { font-family: Michroma, 'Space Grotesk', system-ui, sans-serif; font-size: 1.3rem; color: #a8f0a0;
           letter-spacing: .04em; margin: 0 0 1.25rem; overflow-wrap: anywhere; }
      .bridge { display: inline-flex; align-items: center; gap: 18px; background: #212525;
                border-radius: 999px; padding: 18px 28px; box-shadow: 0 4px 24px rgba(0, 0, 0, .4);
                margin: 0 0 1.5rem; }
      .bridge .logo { width: 34px; height: 34px; display: block; }
      .bridge .etc { width: 40px; height: 40px; }
      .bridge .arrow { width: 30px; height: 12px; display: block; }
      p { margin: .25rem 0; color: rgba(221, 255, 220, .55); }
      a { color: #a8f0a0; }
    </style>
    </head>
    <body><main>
    <h1>${cfg.domain}</h1>
    <div class="bridge" role="img" aria-label="Discord bridged to Matrix by Ethereum Classic">
      <svg class="logo" viewBox="0 0 24 24" fill="#ddffdc" xmlns="http://www.w3.org/2000/svg"><path d="M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z"/></svg>
      <svg class="arrow" viewBox="0 0 30 12" fill="none" stroke="#a8f0a0" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><path d="M4 6h22M8 2 4 6l4 4M22 2l4 4-4 4"/></svg>
      <svg class="etc" viewBox="-43.4 0 220.5 220.5" fill="#a8f0a0" xmlns="http://www.w3.org/2000/svg"><path d="m2.4 98.8 65-27.4 63 28.1-63.1-99.5z"/><path d="m.2 129.2 64.9 37.6 66.2-37.6-65.6 91.3z"/><path d="m67.7 84.8-67.7 28.5 67.7 37.6 65.8-36.8z"/></svg>
      <svg class="arrow" viewBox="0 0 30 12" fill="none" stroke="#a8f0a0" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><path d="M4 6h22M8 2 4 6l4 4M22 2l4 4-4 4"/></svg>
      <svg class="logo" viewBox="0 0 24 24" fill="#ddffdc" xmlns="http://www.w3.org/2000/svg"><path d="M.632.55v22.9H2.28V24H0V0h2.28v.55zm7.043 7.26v1.157h.033c.309-.443.683-.784 1.117-1.024.433-.245.936-.365 1.5-.365.54 0 1.033.107 1.481.314.448.208.785.582 1.02 1.108.254-.374.6-.706 1.034-.992.434-.287.95-.43 1.546-.43.453 0 .872.056 1.26.167.388.11.716.286.993.53.276.245.489.559.646.951.152.392.23.863.23 1.417v5.728h-2.349V11.52c0-.286-.01-.559-.032-.812a1.755 1.755 0 0 0-.18-.66 1.106 1.106 0 0 0-.438-.448c-.194-.11-.457-.166-.785-.166-.332 0-.6.064-.803.189a1.38 1.38 0 0 0-.48.499 1.946 1.946 0 0 0-.231.696 5.56 5.56 0 0 0-.06.785v4.768h-2.35v-4.8c0-.254-.004-.503-.018-.752a2.074 2.074 0 0 0-.143-.688 1.052 1.052 0 0 0-.415-.503c-.194-.125-.476-.19-.854-.19-.111 0-.259.024-.439.074-.18.051-.36.143-.53.282-.171.138-.319.337-.439.595-.12.259-.18.6-.18 1.02v4.966H5.46V7.81zm15.693 15.64V.55H21.72V0H24v24h-2.28v-.55z"/></svg>
    </div>
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
