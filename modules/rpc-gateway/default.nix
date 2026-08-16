# Public JSON-RPC gateway: Caddy terminating TLS in front of proxyd
# (ethereum-optimism's RPC reverse proxy) in front of one or more
# execution-client endpoints. This is the "rpc-gateway" piece from the
# Triforce design doc in its single-node form; the same module fronts a
# regional edge later by listing more backends.
#
# Division of labour: Caddy owns the domain (ACME certs, HTTP->HTTPS,
# compression) and forwards everything to proxyd on loopback. proxyd
# owns the RPC layer: method allowlisting (anything not in
# `allowedMethods` is rejected before it touches a node), per-IP rate
# limiting keyed on the X-Forwarded-For that Caddy appends, retries,
# and backend health.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.rpcGateway;

  tomlFormat = pkgs.formats.toml { };

  # Every allowed method maps to the single "main" backend group.
  # proxyd rejects unmapped methods with `whitelist_error_message`.
  methodMappings = lib.genAttrs cfg.allowedMethods (_: "main");

  proxydConfig = lib.recursiveUpdate (
    {
      server = {
        rpc_host = "127.0.0.1";
        rpc_port = cfg.proxydPort;
        # WS off until a node exposes it and a use case exists.
        ws_port = 0;
        max_body_size_bytes = 10485760;
        # Browser dApps call public RPCs cross-origin; without this the
        # preflight fails and only server-side callers can use the
        # endpoint (same motivation as modules/rpc-cors-proxy).
        allow_all_origins = true;
        log_level = "info";
      };

      rate_limit = {
        # In-memory limiter (no redis): per-IP token bucket of
        # `base_rate` requests per `base_interval`. Single-instance
        # deployment, so shared limiter state buys nothing.
        base_rate = cfg.rateLimit.rate;
        base_interval = cfg.rateLimit.interval;
        # Caddy appends the real client IP to X-Forwarded-For; proxyd
        # keys its buckets off that header by default. Loopback traffic
        # would otherwise all share one bucket.
        error_message = "rate limit exceeded, slow down";
      };

      backend = {
        response_timeout_seconds = 20;
        max_response_size_bytes = 26214400;
        max_retries = 2;
        out_of_service_seconds = 30;
      };

      backends.node = {
        rpc_url = cfg.upstreamUrl;
        max_rps = 0; # unlimited; the per-IP frontend limit is the throttle
      };

      backend_groups.main.backends = [ "node" ];

      rpc_method_mappings = methodMappings;
      whitelist_error_message = "method not available on this endpoint";
    }
    // lib.optionalAttrs cfg.metrics.enable {
      metrics = {
        enabled = true;
        host = "127.0.0.1";
        inherit (cfg.metrics) port;
      };
    }
  ) cfg.extraProxydConfig;

  configFile = tomlFormat.generate "proxyd.toml" proxydConfig;
in
{
  options.rpcGateway = {
    enable = lib.mkEnableOption "Caddy + proxyd JSON-RPC gateway";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "de.rpc.classix.dev";
      description = "Public hostname. Caddy provisions the ACME cert.";
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      example = "ops@classix.dev";
      description = "ACME registration email for Caddy.";
    };

    upstreamUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8545";
      description = "Execution-client JSON-RPC endpoint proxyd forwards to.";
    };

    proxydPort = lib.mkOption {
      type = lib.types.port;
      default = 8580;
      description = "Loopback port proxyd listens on (Caddy's upstream).";
    };

    proxydPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/proxyd { };
      defaultText = lib.literalExpression "packages/proxyd";
      description = "proxyd package to run.";
    };

    allowedMethods = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # The non-archive read set plus transaction submission. No
      # trace/debug/admin, no wide-open eth_getLogs protection here
      # (proxyd caps ranges only in consensus mode), so getLogs stays
      # in on the assumption the rate limit bounds the damage. Drop it
      # per-deploy if the node starts hurting.
      default = [
        "eth_blockNumber"
        "eth_call"
        "eth_chainId"
        "eth_estimateGas"
        "eth_feeHistory"
        "eth_gasPrice"
        "eth_getBalance"
        "eth_getBlockByHash"
        "eth_getBlockByNumber"
        "eth_getBlockReceipts"
        "eth_getBlockTransactionCountByHash"
        "eth_getBlockTransactionCountByNumber"
        "eth_getCode"
        "eth_getLogs"
        "eth_getStorageAt"
        "eth_getTransactionByBlockHashAndIndex"
        "eth_getTransactionByBlockNumberAndIndex"
        "eth_getTransactionByHash"
        "eth_getTransactionCount"
        "eth_getTransactionReceipt"
        "eth_getUncleByBlockHashAndIndex"
        "eth_getUncleByBlockNumberAndIndex"
        "eth_getUncleCountByBlockHash"
        "eth_getUncleCountByBlockNumber"
        "eth_maxPriorityFeePerGas"
        "eth_sendRawTransaction"
        "eth_syncing"
        "net_version"
        "web3_clientVersion"
        "web3_sha3"
      ];
      description = ''
        JSON-RPC methods the gateway forwards. Everything else is
        rejected by proxyd before reaching the node.
      '';
    };

    rateLimit = {
      rate = lib.mkOption {
        type = lib.types.int;
        default = 25;
        description = "Requests allowed per IP per interval.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "1s";
        description = "Rate-limit window (Go duration string).";
      };
    };

    metrics = {
      enable = lib.mkEnableOption "proxyd Prometheus metrics (loopback)";

      port = lib.mkOption {
        type = lib.types.port;
        default = 9761;
        description = "Loopback port for proxyd's /metrics.";
      };
    };

    extraProxydConfig = lib.mkOption {
      inherit (tomlFormat) type;
      default = { };
      example = lib.literalExpression ''
        {
          rate_limit.method_overrides.eth_getLogs = {
            limit = 2;
            interval = "1s";
          };
        }
      '';
      description = ''
        Deep-merged over the generated proxyd config, wins conflicts.
        Full option reference:
        https://github.com/ethereum-optimism/infra/blob/main/proxyd/example.config.toml
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.proxyd = {
      description = "proxyd JSON-RPC proxy for ${cfg.domain}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.proxydPackage} ${configFile}";
        Restart = "always";
        RestartSec = 2;

        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    services.caddy = {
      enable = true;
      email = cfg.acmeEmail;
      virtualHosts.${cfg.domain}.extraConfig = ''
        encode gzip
        reverse_proxy 127.0.0.1:${toString cfg.proxydPort}
      '';
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
