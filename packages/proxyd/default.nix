# proxyd, Optimism's JSON-RPC reverse proxy
# (ethereum-optimism/infra, `proxyd/` subdirectory). Fronts one or more
# execution-client RPC endpoints with method allowlisting, per-IP rate
# limiting, retries, caching, and consensus-aware load balancing. The
# `rpc-gateway` NixOS module runs it behind Caddy.
#
# Release tags are per-component (`proxyd/vX.Y.Z`). Bump `version`,
# `hash`, and `vendorHash` together.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "proxyd";
  version = "4.29.0";

  src = fetchFromGitHub {
    owner = "ethereum-optimism";
    repo = "infra";
    tag = "proxyd/v${version}";
    hash = "sha256-TF8TJ7D7GvrySNhario5i3ER4QgYY3KoTu0GHhNaCNw=";
  };

  # The repo is a multi-module monorepo; proxyd is its own Go module.
  sourceRoot = "${src.name}/proxyd";

  vendorHash = "sha256-NHrfg+YxdnY73BbpIXmgM/Ch9s+bfC0Po2ZJfesKGTU=";

  subPackages = [ "cmd/proxyd" ];

  # Tests hit the network (spawn backends on localhost and require
  # redis for some suites); the build sandbox forbids both.
  doCheck = false;

  ldflags = [
    "-s"
    "-w"
    "-X main.GitVersion=v${version}"
  ];

  meta = with lib; {
    description = "JSON-RPC reverse proxy with method allowlisting, rate limiting, and backend load balancing";
    homepage = "https://github.com/ethereum-optimism/infra/tree/main/proxyd";
    license = licenses.mit;
    mainProgram = "proxyd";
  };
}
