# Every option exposed by the safe-multisig module. The library ships
# almost no defaults. Only `branding.appName`, `services`, and a few
# `null` fallbacks have `default = ...` here. Everything else is
# mandatory and must be set in your consumer flake.
{ lib, ... }:
{
  options.safeMultisig = with lib; {

    # ── Per-deploy identity ──────────────────────────────────────────────
    domain = mkOption {
      type = types.str;
      example = "multisig.example.com";
      description = ''
        Apex hostname. The UI is served here. The internal compose stack
        exposes its backends behind path prefixes on the apex (`/cgw`,
        `/cfg`, `/txs`, `/events`).
      '';
    };

    hostName = mkOption {
      type = types.str;
      example = "safe-multisig";
      description = "NixOS hostname.";
    };

    timeZone = mkOption {
      type = types.str;
      example = "Europe/Berlin";
      description = "Host timezone (IANA name).";
    };

    acmeEmail = mkOption {
      type = types.str;
      example = "ops@example.com";
      description = "Contact email registered with Let's Encrypt for ACME certs.";
    };

    sshAuthorizedKeys = mkOption {
      type = types.listOf types.str;
      example = [ "ssh-ed25519 AAAA... operator@laptop" ];
      description = "SSH public keys authorised for root login.";
    };

    tlsEnabled = mkOption {
      type = types.bool;
      example = true;
      description = ''
        Issue Let's Encrypt certs via ACME. DNS for `domain` and its
        subdomains must point at this host before the first rebuild.
      '';
    };

    # ── Static assets ────────────────────────────────────────────────────
    staticAssets = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "./assets";
      description = ''
        Directory served at `https://<domain>/assets/`. Use it for chain
        logos and any other static file referenced from a chain config
        (`chains.<name>.nativeCurrency.logoUri`,
        `chains.<name>.chainLogoUri`). When null, `/assets/` is not
        served.
      '';
    };

    # ── Branding ─────────────────────────────────────────────────────────
    # Three-piece API:
    #   - appName: maps to NEXT_PUBLIC_BRAND_NAME (upstream-supported).
    #   - pack:    optional source-tree overlay for richer branding.
    #   - theme:   colours surfaced via cfg-service on every chain.
    branding = {
      appName = mkOption {
        type = types.str;
        default = "Safe Wallet";
        example = "Acme Multi-Sig";
        description = ''
          Product name shown in page title, headers, and footer. Wired
          into the bundle as `NEXT_PUBLIC_BRAND_NAME`, the
          upstream-supported brand swap. Works with or without
          `branding.pack`. Defaults to upstream Safe's vanilla name.
        '';
      };

      pack = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              patches = mkOption {
                type = types.listOf types.path;
                default = [ ];
                description = ''
                  Git patches applied with `applyPatches` to
                  safe-wallet-monorepo before build. Use these for
                  structural changes to React components / CSS.
                '';
              };
              postPatch = mkOption {
                type = types.lines;
                default = "";
                description = ''
                  Shell snippet appended after `patches` are applied.
                  Use this for drop-in additions of new files (favicons,
                  fonts, replacement assets) via plain `cp` calls.
                '';
              };
              extraEnv = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = ''
                  Extra build-time env vars passed to `next build`. Use
                  this for any `NEXT_PUBLIC_*` values your patches read
                  at compile time (taglines, footer links, notification
                  banners, etc.).
                '';
              };
            };
          }
        );
        default = null;
        description = ''
          Optional source-tree overlay applied to safe-wallet-monorepo
          before build. A self-contained set of patches, postPatch
          script, and extra `NEXT_PUBLIC_*` env vars. When null,
          vanilla Safe is built with only `appName` swapped.

          Consumers typically place their pack under `./branding/` in
          their flake and pass it here via `pkgs.callPackage`.
        '';
      };

      theme = {
        textColor = mkOption {
          type = types.str;
          example = "#ffffff";
          description = ''
            Theme text colour registered with cfg-service for every
            chain. Surfaced via `/v2/chains` to clients.
          '';
        };
        backgroundColor = mkOption {
          type = types.str;
          example = "#000000";
          description = "Theme background colour registered with cfg-service.";
        };
      };
    };

    # ── Client Gateway (CGW) tuning ─────────────────────────────────────
    cgw = {
      pricesProvider = {
        apiKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "CG-xxxxxxxxxxxxxxxx";
          description = "Coingecko API key. Sets `PRICES_PROVIDER_API_KEY`.";
        };
        apiBaseUri = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://pro-api.coingecko.com/api/v3";
          description = "Override the prices-provider base URI (Pro API uses a different host). Sets `PRICES_PROVIDER_API_BASE_URI`.";
        };
        tokenPricesTtlSeconds = mkOption {
          type = types.ints.positive;
          default = 3600;
          description = "ERC-20 token price cache TTL (seconds). Sets `PRICES_TTL_SECONDS`. Upstream default 300.";
        };
        nativeCoinPricesTtlSeconds = mkOption {
          type = types.ints.positive;
          default = 3600;
          description = "Native-coin price cache TTL (seconds). Sets `NATIVE_COINS_PRICES_TTL_SECONDS`. Upstream default 100.";
        };
      };
      zerion = {
        apiKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Zerion API key for `/v1/.../positions/<fiat>`. Sets `ZERION_API_KEY`.";
        };
      };
    };

    # ── Transaction service indexer tuning ──────────────────────────────
    txs = {
      eventsBlockProcessLimit = mkOption {
        type = types.ints.positive;
        default = 50;
        description = ''
          Initial number of blocks the txs events indexer processes per
          iteration (`ETH_EVENTS_BLOCK_PROCESS_LIMIT`). Auto-adjusts up to
          `eventsBlockProcessLimitMax`. Upstream default 50, conservative
          for any real chain; bump (e.g. 1000) for faster backfill on
          chains the indexer is many blocks behind.
        '';
      };
      eventsBlockProcessLimitMax = mkOption {
        type = types.ints.unsigned;
        default = 10000;
        description = ''
          Max blocks-per-iteration for the auto-adjusting events indexer
          (`ETH_EVENTS_BLOCK_PROCESS_LIMIT_MAX`). 0 disables the upper
          cap entirely.
        '';
      };
    };

    # ── cfg-service service keys (Service.key in chains_service) ────────
    # The frontend (safe-wallet-web) issues `/v2/chains?serviceKey=WALLET_WEB`.
    # cfg-service `get_object_or_404(Service, key=service_key)` returns 404
    # if no matching Service row exists, and every chain query falls over.
    # Listed keys are seeded by `safe-multisig-chain-bootstrap` on each rebuild.
    services = mkOption {
      type = types.listOf types.str;
      default = [ "WALLET_WEB" ];
      example = [
        "WALLET_WEB"
        "MOBILE"
      ];
      description = ''
        Service keys to register in cfg-service so that the
        `/v2/chains/{service_key}/` endpoint resolves. Defaults to
        `[ "WALLET_WEB" ]`, the only key safe-wallet-web sends.
      '';
    };

    # ── Chains (registered in safe-config-service at first boot) ─────────
    # The bundled compose project ships a single `txs` indexer, so exactly
    # one chain in `chains` is "primary" (its RPC URL and chain id are
    # baked into the indexer + the wallet bundle). Multi-chain operation
    # requires running additional `txs` stacks out of band.
    primaryChain = mkOption {
      type = types.str;
      example = "etc";
      description = ''
        Attrset key in `chains` of the chain whose RPC URL and chain id
        are baked into the upstream `txs` indexer (via the compose
        override) and the wallet bundle's
        `NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID`. Must match a key in
        `chains`. Other chains in `chains` are still registered with
        cfg-service but their transactions are not indexed by this
        deployment.
      '';
    };

    chains = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            chainId = mkOption { type = types.int; };
            shortName = mkOption { type = types.str; };
            chainName = mkOption { type = types.str; };
            description = mkOption {
              type = types.str;
              default = "";
            };
            isTestnet = mkOption {
              type = types.bool;
              default = false;
            };
            l2 = mkOption {
              type = types.bool;
              default = false;
            };
            rpcUri = mkOption { type = types.str; };
            blockExplorerUriTemplate = mkOption {
              type = types.attrsOf types.str;
              description = "Map of { address, txHash, api } URL templates.";
            };
            transactionService = mkOption { type = types.str; };
            nativeCurrency = mkOption {
              type = types.submodule {
                options = {
                  name = mkOption { type = types.str; };
                  symbol = mkOption { type = types.str; };
                  decimals = mkOption {
                    type = types.int;
                    default = 18;
                  };
                  logoUri = mkOption {
                    type = types.str;
                    description = ''
                      URL to currency logo image. Safe Client Gateway
                      Zod-validates this as a non-null string at runtime
                      (`/v2/chains` 404s the whole list if any chain has
                      a null logo). Use a placeholder URL if the chain
                      doesn't have an official logo.
                    '';
                  };
                };
              };
            };
            chainLogoUri = mkOption {
              type = types.nullOr types.str;
              default = null;
            };

            # Coingecko / external provider IDs that safe-config-service
            # uses to populate native-coin price and balances data.
            # Without these the wallet shows $0 for native balances.
            pricesProvider = mkOption {
              type = types.submodule {
                options = {
                  nativeCoin = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "ethereum-classic";
                    description = "Coingecko id for the native coin.";
                  };
                  chainName = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "ethereum-classic";
                    description = "Coingecko id for the chain (token prices).";
                  };
                };
              };
              default = { };
            };
            balancesProvider = mkOption {
              type = types.submodule {
                options = {
                  chainName = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "ethereum-classic";
                    description = "External balances-aggregator chain name.";
                  };
                  enabled = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Enable the external balances aggregator (Zerion).";
                  };
                };
              };
              default = { };
            };
          };
        }
      );
    };
  };
}
