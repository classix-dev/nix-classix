# Static-export build of safe-global/safe-wallet-monorepo's `apps/web`
# workspace. Replaces the upstream container that runs `next build` at
# startup.
#
# `next.config.mjs` already sets `output: 'export'`, so `next build`
# emits a static directory to `apps/web/out/`. The derivation copies
# that to `$out`; the NixOS module at `modules/safe-multisig/ui.nix`
# serves it via the host nginx.
#
# Per-deploy values (gateway URL, chain id, branding) are baked in at
# build time, so any change requires a rebuild (~5-10 min, mostly
# next-export's single-threaded prerender). Pin a binary cache that
# has the bundle to skip the rebuild on consumers.
{
  lib,
  stdenv,
  yarn-berry,
  nodejs_20,
  cacert,
  src,
  appName ? "Safe Wallet",
  gatewayUrl ? "https://safe-client.safe.global",
  defaultChainId ? 1,
  isProduction ? true,
  # Additional NEXT_PUBLIC_* / build-time env vars, spread onto the
  # derivation. Used by a consumer's branding pack to inject any
  # NEXT_PUBLIC_* values its patches read at compile time. Empty `{}`
  # for a vanilla Safe build.
  extraEnv ? { },
}:
let
  version = "1.88.0";

  # Yarn Berry global cache, populated by a fixed-output derivation. The
  # `outputHash` below pins the entire `apps/web` dependency tree. Bump
  # it whenever `yarn.lock` changes (Nix will print the expected hash on
  # mismatch).
  yarnCache = stdenv.mkDerivation {
    pname = "safe-multisig-ui-yarn-cache";
    inherit version src;

    nativeBuildInputs = [
      yarn-berry
      nodejs_20
      cacert
    ];

    NODE_EXTRA_CA_CERTS = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    buildPhase = ''
      runHook preBuild

      export HOME="$NIX_BUILD_TOP/home"
      mkdir -p "$HOME"
      export YARN_GLOBAL_FOLDER="$out"
      export YARN_ENABLE_TELEMETRY=0
      export YARN_ENABLE_GLOBAL_CACHE=true

      # `--mode=skip-build` populates the cache without running install
      # scripts; the source repo also sets `enableScripts: false`, so this
      # is belt-and-braces.
      yarn install --immutable --mode=skip-build

      runHook postBuild
    '';

    # Cache content already lives at $out via YARN_GLOBAL_FOLDER.
    installPhase = "true";
    dontFixup = true;

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-s4vHYBdPD6t6g0ASeGrmjPi/lRpLAXTTUkdyWBbRhp4=";
  };
in
stdenv.mkDerivation (
  {
    pname = "safe-multisig-ui";
    inherit version src;

    nativeBuildInputs = [
      yarn-berry
      nodejs_20
    ];

    # Brand name flows through `apps/web/src/config/constants.ts:BRAND_NAME`.
    # Set NEXT_PUBLIC_BRAND_NAME and every consumer (page titles, OG
    # tags, in-app references) picks it up.
    NEXT_PUBLIC_BRAND_NAME = appName;
    NEXT_PUBLIC_GATEWAY_URL_PRODUCTION = gatewayUrl;
    NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID = toString defaultChainId;
    NEXT_PUBLIC_IS_PRODUCTION = if isProduction then "true" else "false";
    NEXT_TELEMETRY_DISABLED = "1";

    # The prerender phase peaks past 5 GB of Node heap. Node 20's default
    # cap is ~2 GB and triggers SIGABRT; bump it. 6 GB is comfortable on
    # any host with reasonable headroom (this build is not intended to
    # run on a 7 GB GH-hosted runner).
    NODE_OPTIONS = "--max-old-space-size=6144";

    postPatch = ''
      # `yarn fetch-chains` makes a network call to seed chain metadata,
      # incompatible with the Nix build sandbox. The app falls back to a
      # runtime fetch from CGW (which is what fetch-chains itself only
      # *speeds up*; see its own header comment). `--no-lint` skips
      # eslint enforcement (release artefact, not a dev run).
      substituteInPlace apps/web/package.json \
        --replace-fail '"build": "yarn fetch-chains && next build"' \
                       '"build": "next build --no-lint"'

      # `next build` reads chain JSON from this path; create an empty
      # placeholder so the app falls back to its runtime CGW fetch.
      mkdir -p apps/web/src/config/__generated__
      echo '[]' > apps/web/src/config/__generated__/chains.json

      # Show 2 decimal places for fiat values under $100. Upstream's
      # threshold is $1, which renders e.g. a token priced at $8.41 as
      # "$8". Fine for $bn portfolios, terrible for low-cap chains.
      substituteInPlace packages/utils/src/utils/formatNumber.ts \
        --replace-fail 'Math.abs(float) >= 1 || float === 0 ? 0 : 2' \
                       'Math.abs(float) >= 100 || float === 0 ? 0 : 2'
    '';

    buildPhase = ''
      runHook preBuild

      export HOME="$NIX_BUILD_TOP/home"
      mkdir -p "$HOME"
      export YARN_GLOBAL_FOLDER=${yarnCache}
      export YARN_ENABLE_TELEMETRY=0
      export YARN_ENABLE_GLOBAL_CACHE=true
      # No network in the build sandbox. Fail fast if the cache misses.
      export YARN_ENABLE_NETWORK=0

      # `--mode=skip-build` matches how the cache was populated and avoids
      # running per-package build scripts (cypress binary download, sharp
      # native compile etc.). None of which we need for `next export`.
      yarn install --immutable --immutable-cache --mode=skip-build
      yarn workspace @safe-global/web after-install
      yarn workspace @safe-global/web build

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r apps/web/out/. $out/

      runHook postInstall
    '';

    meta = with lib; {
      description = "Static export of safe-wallet-monorepo apps/web";
      homepage = "https://github.com/safe-global/safe-wallet-monorepo";
      license = licenses.gpl3Only;
    };
  }
  // extraEnv
)
