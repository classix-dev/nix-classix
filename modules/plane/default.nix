# Plane (makeplane/plane) project management, self-hosted community
# edition. Upstream ships no NixOS module or nixpkgs package, only
# docker images and a compose file, so this module runs those images
# via oci-containers/podman and replaces upstream's proxy container
# with the host Caddy. Service topology, env wiring and routing mirror
# deployments/cli/community/docker-compose.yml and
# apps/proxy/Caddyfile.ce at the pinned release.
#
# Division of labour: Caddy owns the domain (ACME certs, gzip) and
# routes path prefixes to the app containers on loopback, exactly as
# upstream's plane-proxy Caddyfile does (/spaces -> space, /god-mode ->
# admin, /live -> live, /api /auth /static -> api, /uploads -> minio,
# everything else -> web). The containers talk to each other over a
# dedicated podman network by name; only the six ports Caddy needs are
# published, and only on loopback.
#
# Secrets never touch the nix store. A root oneshot generates the
# Django secret, the live-server key and the postgres / rabbitmq /
# minio credentials once on first boot into an env file, and every
# container reads them from there. Wiping that file plus the data dir
# resets the instance.
#
# State lives under `dataDir`, which is expected to be a mounted
# volume on cloud deploys. Every unit carries RequiresMountsFor, so
# nothing starts against an unmounted data directory.
#
# First-boot onboarding: browse to https://<domain>/god-mode and
# create the instance admin, then sign up the first workspace user at
# the root. Registration policy is managed from god-mode.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.plane;

  # Outside dataDir on purpose: written by a root oneshot with umask
  # 0077, and it must survive a data-volume wipe no more than the data
  # survives a secrets wipe (the two only work as a pair).
  secretsFile = "/var/lib/plane/secrets.env";

  network = "plane";

  # Loopback ports Caddy proxies to. Internal to this module, the
  # matrix-module synapsePort pattern.
  ports = {
    web = 14100;
    space = 14101;
    admin = 14102;
    live = 14103;
    api = 14104;
    minio = 14105;
  };

  backendImage = "docker.io/makeplane/plane-backend:${cfg.release}";

  # Mirrors the compose file's x-*-env anchors. Passwords and derived
  # URLs (DATABASE_URL, AMQP_URL) live in secretsFile, not here.
  dbEnv = {
    PGHOST = "plane-db";
    PGDATABASE = "plane";
    POSTGRES_USER = "plane";
    POSTGRES_DB = "plane";
    POSTGRES_PORT = "5432";
    PGDATA = "/var/lib/postgresql/data";
  };

  redisEnv = {
    REDIS_HOST = "plane-redis";
    REDIS_PORT = "6379";
    REDIS_URL = "redis://plane-redis:6379/";
  };

  mqEnv = {
    RABBITMQ_HOST = "plane-mq";
    RABBITMQ_PORT = "5672";
    RABBITMQ_DEFAULT_USER = "plane";
    RABBITMQ_DEFAULT_VHOST = "plane";
    RABBITMQ_VHOST = "plane";
  };

  awsEnv = {
    AWS_REGION = "";
    AWS_S3_ENDPOINT_URL = "http://plane-minio:9000";
    AWS_S3_BUCKET_NAME = "uploads";
  };

  appEnv = {
    WEB_URL = "https://${cfg.domain}";
    APP_DOMAIN = cfg.domain;
    DEBUG = "0";
    CORS_ALLOWED_ORIGINS = "https://${cfg.domain}";
    GUNICORN_WORKERS = "1";
    USE_MINIO = "1";
    # TLS terminates at Caddy; minio itself stays plain http on the
    # container network.
    MINIO_ENDPOINT_SSL = "0";
    API_KEY_RATE_LIMIT = "60/minute";
    FILE_SIZE_LIMIT = toString cfg.fileSizeLimit;
  }
  // dbEnv
  // redisEnv
  // mqEnv
  // awsEnv;

  backendUnits = [
    "podman-plane-api"
    "podman-plane-worker"
    "podman-plane-beat"
  ];

  # Explicit, not derived from config, so a future co-tenant module's
  # containers don't inherit Plane's ordering.
  containerUnits = map (n: "podman-${n}") [
    "plane-web"
    "plane-space"
    "plane-admin"
    "plane-live"
    "plane-api"
    "plane-worker"
    "plane-beat"
    "plane-db"
    "plane-redis"
    "plane-mq"
    "plane-minio"
  ];
in
{
  options.plane = {
    enable = lib.mkEnableOption "Plane project management (community edition, containers + Caddy)";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "plane.hq.classix.dev";
      description = "Public hostname. Caddy provisions the ACME cert.";
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      example = "ops@classix.dev";
      description = "ACME registration email for Caddy.";
    };

    release = lib.mkOption {
      type = lib.types.str;
      default = "v1.4.1";
      description = ''
        Upstream release tag for the makeplane/* images. Bump
        deliberately; the migrator runs on every switch, and upstream
        migrations are forward-only.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/data/plane";
      description = ''
        Root for all container state (postgres, redis, rabbitmq,
        uploads, api logs). Point it at the mounted data volume.
      '';
    };

    fileSizeLimit = lib.mkOption {
      type = lib.types.int;
      default = 5242880;
      description = "Upload size cap in bytes, enforced by Caddy and the api.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = lib.mkDefault "podman";

    virtualisation.oci-containers.containers = {
      plane-web = {
        image = "docker.io/makeplane/plane-frontend:${cfg.release}";
        ports = [ "127.0.0.1:${toString ports.web}:3000" ];
        extraOptions = [ "--network=${network}" ];
        dependsOn = [ "plane-api" ];
      };

      plane-space = {
        image = "docker.io/makeplane/plane-space:${cfg.release}";
        ports = [ "127.0.0.1:${toString ports.space}:3000" ];
        extraOptions = [ "--network=${network}" ];
        dependsOn = [ "plane-api" ];
      };

      plane-admin = {
        image = "docker.io/makeplane/plane-admin:${cfg.release}";
        ports = [ "127.0.0.1:${toString ports.admin}:3000" ];
        extraOptions = [ "--network=${network}" ];
        dependsOn = [ "plane-api" ];
      };

      plane-live = {
        image = "docker.io/makeplane/plane-live:${cfg.release}";
        ports = [ "127.0.0.1:${toString ports.live}:3000" ];
        environment = redisEnv // {
          API_BASE_URL = "http://plane-api:8000";
        };
        # LIVE_SERVER_SECRET_KEY
        environmentFiles = [ secretsFile ];
        extraOptions = [ "--network=${network}" ];
        dependsOn = [ "plane-api" ];
      };

      plane-api = {
        image = backendImage;
        cmd = [ "./bin/docker-entrypoint-api.sh" ];
        ports = [ "127.0.0.1:${toString ports.api}:8000" ];
        environment = appEnv;
        environmentFiles = [ secretsFile ];
        volumes = [ "${cfg.dataDir}/logs/api:/code/plane/logs" ];
        extraOptions = [ "--network=${network}" ];
        dependsOn = [
          "plane-db"
          "plane-redis"
          "plane-mq"
          "plane-minio"
        ];
      };

      plane-worker = {
        image = backendImage;
        cmd = [ "./bin/docker-entrypoint-worker.sh" ];
        environment = appEnv;
        environmentFiles = [ secretsFile ];
        volumes = [ "${cfg.dataDir}/logs/worker:/code/plane/logs" ];
        extraOptions = [ "--network=${network}" ];
        dependsOn = [
          "plane-db"
          "plane-redis"
          "plane-mq"
        ];
      };

      plane-beat = {
        image = backendImage;
        cmd = [ "./bin/docker-entrypoint-beat.sh" ];
        environment = appEnv;
        environmentFiles = [ secretsFile ];
        volumes = [ "${cfg.dataDir}/logs/beat:/code/plane/logs" ];
        extraOptions = [ "--network=${network}" ];
        dependsOn = [
          "plane-db"
          "plane-redis"
          "plane-mq"
        ];
      };

      plane-db = {
        image = "docker.io/library/postgres:15.7-alpine";
        cmd = [
          "postgres"
          "-c"
          "max_connections=1000"
        ];
        environment = dbEnv;
        # POSTGRES_PASSWORD
        environmentFiles = [ secretsFile ];
        volumes = [ "${cfg.dataDir}/postgres:/var/lib/postgresql/data" ];
        extraOptions = [ "--network=${network}" ];
      };

      plane-redis = {
        image = "docker.io/valkey/valkey:7.2.11-alpine";
        volumes = [ "${cfg.dataDir}/redis:/data" ];
        extraOptions = [ "--network=${network}" ];
      };

      plane-mq = {
        image = "docker.io/library/rabbitmq:3.13.6-management-alpine";
        environment = mqEnv;
        # RABBITMQ_DEFAULT_PASS
        environmentFiles = [ secretsFile ];
        volumes = [ "${cfg.dataDir}/rabbitmq:/var/lib/rabbitmq" ];
        extraOptions = [ "--network=${network}" ];
      };

      plane-minio = {
        image = "docker.io/minio/minio:latest";
        cmd = [
          "server"
          "/export"
        ];
        ports = [ "127.0.0.1:${toString ports.minio}:9000" ];
        # MINIO_ROOT_USER / MINIO_ROOT_PASSWORD
        environmentFiles = [ secretsFile ];
        volumes = [ "${cfg.dataDir}/uploads:/export" ];
        extraOptions = [ "--network=${network}" ];
      };
    };

    # mkMerge, not //: the backend units appear in two of these sets
    # and their dependency lists must combine, not overwrite.
    systemd.services = lib.mkMerge [
      (lib.genAttrs containerUnits (_: {
        after = [
          "plane-secrets.service"
          "plane-network.service"
        ];
        requires = [
          "plane-secrets.service"
          "plane-network.service"
        ];
        unitConfig.RequiresMountsFor = [ cfg.dataDir ];
      }))
      {
        plane-network = {
          description = "Podman network for the Plane containers";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.podman}/bin/podman network exists ${network} \
              || ${pkgs.podman}/bin/podman network create ${network}
          '';
        };

        plane-secrets = {
          description = "Generate the Plane credentials env file";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            if [ ! -f ${secretsFile} ]; then
              mkdir -p ${dirOf secretsFile}
              gen() { ${pkgs.coreutils}/bin/tr -dc A-Za-z0-9 < /dev/urandom | ${pkgs.coreutils}/bin/head -c "$1"; }
              pg_pass=$(gen 48)
              mq_pass=$(gen 48)
              minio_user=$(gen 20)
              minio_pass=$(gen 48)
              cat > ${secretsFile} <<EOF
            SECRET_KEY=$(gen 50)
            LIVE_SERVER_SECRET_KEY=$(gen 64)
            POSTGRES_PASSWORD=$pg_pass
            DATABASE_URL=postgresql://plane:$pg_pass@plane-db/plane
            RABBITMQ_DEFAULT_PASS=$mq_pass
            RABBITMQ_PASSWORD=$mq_pass
            AMQP_URL=amqp://plane:$mq_pass@plane-mq:5672/plane
            MINIO_ROOT_USER=$minio_user
            MINIO_ROOT_PASSWORD=$minio_pass
            AWS_ACCESS_KEY_ID=$minio_user
            AWS_SECRET_ACCESS_KEY=$minio_pass
            EOF
            fi
          '';
        };

        # Upstream runs the migrator as a separate one-shot container on
        # every deploy; api/worker block on wait_for_migrations until it
        # finishes, so ordering the backends after it is belt-and-braces.
        plane-migrator = {
          description = "Plane database migrations";
          after = [
            "plane-secrets.service"
            "plane-network.service"
            "podman-plane-db.service"
            "podman-plane-mq.service"
            "podman-plane-redis.service"
          ];
          requires = [
            "plane-secrets.service"
            "plane-network.service"
            "podman-plane-db.service"
          ];
          wantedBy = [ "multi-user.target" ];
          unitConfig.RequiresMountsFor = [ cfg.dataDir ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.podman}/bin/podman run --rm \
              --network=${network} \
              --env-file ${secretsFile} \
              ${
                lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${k}=${lib.escapeShellArg v}") appEnv)
              } \
              ${backendImage} ./bin/docker-entrypoint-migrator.sh
          '';
        };
      }
      (lib.genAttrs backendUnits (_: {
        after = [ "plane-migrator.service" ];
        requires = [ "plane-migrator.service" ];
      }))
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 root root -"
      "d ${cfg.dataDir}/logs 0750 root root -"
    ];

    # Same routing as upstream's plane-proxy Caddyfile.ce. Caddy sorts
    # same-directive matchers by path length, so the specific prefixes
    # win over the trailing catch-all regardless of order here.
    services.caddy = {
      enable = true;
      email = cfg.acmeEmail;
      virtualHosts.${cfg.domain}.extraConfig = ''
        encode gzip
        request_body {
          max_size ${toString cfg.fileSizeLimit}
        }
        redir /spaces /spaces/ permanent
        redir /god-mode /god-mode/ permanent
        reverse_proxy /spaces/* 127.0.0.1:${toString ports.space}
        reverse_proxy /god-mode/* 127.0.0.1:${toString ports.admin}
        reverse_proxy /live/* 127.0.0.1:${toString ports.live}
        reverse_proxy /api/* 127.0.0.1:${toString ports.api}
        reverse_proxy /auth/* 127.0.0.1:${toString ports.api}
        reverse_proxy /static/* 127.0.0.1:${toString ports.api}
        reverse_proxy /uploads/* 127.0.0.1:${toString ports.minio}
        reverse_proxy /uploads 127.0.0.1:${toString ports.minio}
        reverse_proxy 127.0.0.1:${toString ports.web}
      '';
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
