# Nethermind node on Ethereum Classic, running the ETC Cooperative
# plugin bundle from `packages/nethermind-etc`. One systemd service,
# JSON-RPC bound to localhost by default (front it with
# `modules/rpc-gateway` for public exposure), p2p open in the firewall.
#
# The bundle's own `classic.cfg` carries the network defaults (chainspec,
# genesis hash, discovery DNS, JSON-RPC on 127.0.0.1:8545) so this
# module only layers deploy-level settings on top as `--Section.Key`
# CLI flags, which take precedence over the .cfg. Anything not covered
# by an option here goes through `settings` verbatim.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nethermindEtc;

  # `--Section.Key value` flags from the merged settings attrset.
  # Booleans render as lowercase strings the .NET config binder expects.
  renderValue = v: if lib.isBool v then lib.boolToString v else toString v;
  settingsFlags = lib.concatLists (
    lib.mapAttrsToList (name: value: [
      "--${name}"
      (renderValue value)
    ]) cfg.settings
  );
in
{
  options.nethermindEtc = {
    enable = lib.mkEnableOption "Nethermind Ethereum Classic node";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/nethermind-etc { };
      defaultText = lib.literalExpression "packages/nethermind-etc";
      description = "Nethermind + ETC plugin bundle to run.";
    };

    network = lib.mkOption {
      type = lib.types.enum [
        "classic"
        "mordor"
      ];
      default = "classic";
      description = ''
        Named config from the bundle's `configs/` directory. `classic`
        is ETC mainnet (chain id 61), `mordor` the testnet (63).
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/nethermind-etc";
      description = ''
        Chain database, keystore, and logs. The default is managed via
        systemd `StateDirectory`; point it elsewhere (e.g. a dedicated
        NVMe mount) and the consumer owns creation and permissions.
      '';
    };

    p2pPort = lib.mkOption {
      type = lib.types.port;
      default = 30303;
      description = "devp2p listener and discovery port (TCP + UDP).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the p2p port in the firewall.";
    };

    jsonRpc = {
      address = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          JSON-RPC bind address. Keep it on loopback and let the
          rpc-gateway (or another reverse proxy) do public exposure;
          the engine has no rate limiting or auth of its own.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8545;
        description = "JSON-RPC port.";
      };

      enabledModules = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "Eth"
          "Net"
          "Web3"
          "Health"
        ];
        description = ''
          JSON-RPC module set. The bundle's classic.cfg enables Admin
          and Debug too; this default drops them since anything beyond
          read-path modules on an RPC node widens the attack surface
          the gateway then has to filter.
        '';
      };
    };

    metrics = {
      enable = lib.mkEnableOption "Prometheus /metrics endpoint";

      port = lib.mkOption {
        type = lib.types.port;
        default = 9091;
        description = "Port for the pull-mode Prometheus endpoint.";
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
        ]
      );
      default = { };
      example = lib.literalExpression ''
        {
          "Sync.FastSync" = true;
          "Init.MemoryHint" = 4096000000;
        }
      '';
      description = ''
        Extra `--Section.Key value` flags, passed after the options
        above so they win any overlap. Section and key names as in the
        Nethermind docs (https://docs.nethermind.io/fundamentals/configuration).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.nethermind-etc = {
      isSystemUser = true;
      group = "nethermind-etc";
      home = cfg.dataDir;
    };
    users.groups.nethermind-etc = { };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.p2pPort ];
      allowedUDPPorts = [ cfg.p2pPort ];
    };

    systemd.services.nethermind-etc = {
      description = "Nethermind Ethereum Classic node (${cfg.network})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # The single-file .NET host extracts bundled native libraries at
      # startup; give it a writable, persistent target so the ~300 MB
      # extraction survives restarts instead of landing in a fresh
      # PrivateTmp every time.
      environment.DOTNET_BUNDLE_EXTRACT_BASE_DIR = "/var/cache/nethermind-etc";

      serviceConfig = {
        User = "nethermind-etc";
        Group = "nethermind-etc";
        StateDirectory = lib.mkIf (cfg.dataDir == "/var/lib/nethermind-etc") "nethermind-etc";
        CacheDirectory = "nethermind-etc";
        WorkingDirectory = "${cfg.package}/share/nethermind-etc";

        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "--config"
            cfg.network
            "--data-dir"
            cfg.dataDir
            "--JsonRpc.Enabled"
            "true"
            "--JsonRpc.Host"
            cfg.jsonRpc.address
            "--JsonRpc.Port"
            (toString cfg.jsonRpc.port)
            "--JsonRpc.EnabledModules"
            (lib.concatStringsSep "," cfg.jsonRpc.enabledModules)
          ]
          ++ lib.optionals cfg.metrics.enable [
            "--Metrics.Enabled"
            "true"
            "--Metrics.ExposePort"
            (toString cfg.metrics.port)
          ]
          ++ settingsFlags
        );

        Restart = "always";
        RestartSec = 5;

        # RocksDB holds thousands of SSTs open on a synced chain db;
        # the default 1024 soft limit stalls sync with cryptic
        # "too many open files" corruption warnings.
        LimitNOFILE = 1000000;

        # Hardening. No PrivateUsers: the runtime needs the real uid
        # for its extraction-dir ownership check.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "full";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };
  };
}
