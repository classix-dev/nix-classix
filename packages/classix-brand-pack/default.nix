# Classix brand pack. Returns an attrset matching `branding.pack` on the
# safe-multisig module (`{ patches, postPatch, extraEnv }`). Consumers
# wire it via `safeMultisig.branding.pack = nix-classix.lib.brandPacks.classix { };`
# or via the `flavors.classix` composition (which does this for them).
#
# What the pack adds:
#   - 0001-classix-branding.patch: React/CSS changes to the upstream
#     Safe header (wordmark + tagline), footer (drops the "unofficial
#     distribution" line, adds configurable links), and notification
#     modal.
#   - postPatch: drops Michroma + Space Grotesk webfonts, the apex
#     favicon SVG, and disables typecheck/eslint during `next build`
#     (saves several minutes of single-threaded work per iteration;
#     the static export is the release artefact, not a dev run).
#
# Patch internals retain the historical `CATACOMB_` env-var prefix and
# `catacombEdition` CSS class names. Renaming them everywhere requires
# regenerating the patch against current upstream, tracked as a
# follow-up; the prefix is internal to the patch+extraEnv contract and
# not visible in nix-classix's option surface.
{
  # Per-deploy banner string shown in a top-of-page modal. Empty hides
  # the modal entirely. Defaults to empty (production); deployments
  # override with e.g. "Demo deploy. Do not use with production assets."
  notificationBanner ? "",

  # Apex favicon. Defaults to the ETC chain logo we ship; pass a path
  # to your own SVG to override.
  faviconSvg ? ./assets/etc-logo.svg,
}:
{
  patches = [ ./patches/0001-classix-branding.patch ];

  postPatch = ''
    # Webfonts.
    cp ${./fonts/Michroma-latin.woff2}     apps/web/public/fonts/Michroma-latin.woff2
    cp ${./fonts/SpaceGrotesk-latin.woff2} apps/web/public/fonts/SpaceGrotesk-latin.woff2
    chmod +w apps/web/public/fonts/fonts.css
    cat >> apps/web/public/fonts/fonts.css <<'EOF'

    @font-face {
      font-family: 'Michroma';
      font-display: swap;
      font-weight: 400;
      src: url('/fonts/Michroma-latin.woff2') format('woff2');
    }

    @font-face {
      font-family: 'Space Grotesk';
      font-display: swap;
      font-weight: 500 700;
      src: url('/fonts/SpaceGrotesk-latin.woff2') format('woff2');
    }
    EOF

    # Favicon.
    cp ${faviconSvg} apps/web/public/favicons/icon.svg
    cp ${faviconSvg} apps/web/public/favicons/safari-pinned-tab.svg

    # Skip typecheck + eslint during `next build`. Saves several minutes
    # of single-threaded work per UI rebuild; the static export is the
    # release artefact, not a dev run.
    chmod +w apps/web/next.config.mjs
    sed -i \
      -e "s|output: 'export', // static site export|output: 'export', // static site export\n  typescript: { ignoreBuildErrors: true },|" \
      -e "s|dirs: \['src', 'cypress'\]|dirs: ['src', 'cypress'], ignoreDuringBuilds: true|" \
      apps/web/next.config.mjs
  '';

  extraEnv = {
    NEXT_PUBLIC_CATACOMB_TAGLINE = "classix edition";
    NEXT_PUBLIC_CATACOMB_FOOTER_LINKS = builtins.toJSON [
      {
        label = "classix.dev";
        url = "https://classix.dev";
      }
    ];
    NEXT_PUBLIC_CATACOMB_GITHUB_REPO = "https://github.com/classix-dev/nix-classix";
    NEXT_PUBLIC_CATACOMB_NOTIFICATION = notificationBanner;
  };
}
