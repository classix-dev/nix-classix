# Nethermind with Ethereum Classic support, from the ETC Cooperative's
# plugin release bundles (ETCCooperative/nethermind-etc-plugin). Each
# release repackages the matching upstream Nethermind linux-x64
# self-contained build with the ETC plugin DLL dropped into `plugins/`,
# the `classic`/`mordor` chainspecs into `chainspecs/`, and the
# ready-made `classic.cfg`/`mordor.cfg` into `configs/`. One fetch, no
# .NET toolchain, no assembling Nethermind + plugin ourselves.
#
# The bundle is a .NET single-file publish. Its ELF NEEDED list is just
# glibc + libstdc++ (autoPatchelf handles those), but the runtime
# dlopen()s ICU, OpenSSL, and zlib after start, which autoPatchelf
# cannot see. The bin wrapper prefixes LD_LIBRARY_PATH for those three.
#
# Version pinning: the release tag tracks the upstream Nethermind
# version it was built from (v1.38.1.0 = Nethermind 1.38.1). Bump
# `version` and `hash` together.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  makeWrapper,
  zlib,
  openssl,
  icu,
}:
stdenv.mkDerivation rec {
  pname = "nethermind-etc";
  version = "1.38.1.0";

  src = fetchurl {
    url = "https://github.com/ETCCooperative/nethermind-etc-plugin/releases/download/v${version}/nethermind-etc-v${version}-linux-x64.zip";
    # Matches the `SHA256SUMS` file attached to the same release.
    hash = "sha256-+IOX29Dtto4ac/gRargjQZiFK0Ghw8ANre11u/0rW7Y=";
  };

  nativeBuildInputs = [
    unzip
    autoPatchelfHook
    makeWrapper
  ];

  # For autoPatchelf (libstdc++/libgcc on the main binary).
  buildInputs = [ stdenv.cc.cc.lib ];

  # The zip has no top-level directory.
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/nethermind-etc $out/bin
    cp -r . $out/share/nethermind-etc
    # stdenv drops an `env-vars` scratch file into the build dir, which
    # `sourceRoot = "."` sweeps up with the bundle. Not part of the release.
    rm $out/share/nethermind-etc/env-vars

    # `Nethermind.Runner` is a byte-identical copy of `nethermind`
    # shipped for backwards compatibility. Symlink it instead of
    # doubling the closure by ~293 MB.
    rm $out/share/nethermind-etc/Nethermind.Runner
    ln -s nethermind $out/share/nethermind-etc/Nethermind.Runner

    chmod +x $out/share/nethermind-etc/nethermind

    # Nethermind resolves `configs/`, `chainspecs/`, and `plugins/`
    # relative to the executable's directory, so the wrapper points at
    # the binary in situ rather than copying it into bin/. Consumers
    # still need to set a writable data dir (`--data-dir`) and a
    # writable single-file extraction dir (DOTNET_BUNDLE_EXTRACT_BASE_DIR
    # defaults to $HOME/.net); the NixOS module handles both.
    makeWrapper $out/share/nethermind-etc/nethermind $out/bin/nethermind-etc \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          zlib
          openssl
          icu
        ]
      }

    runHook postInstall
  '';

  # 293 MB single binary; stripping .NET single-file bundles corrupts
  # the embedded assemblies appended after the ELF image.
  dontStrip = true;

  meta = with lib; {
    description = "Nethermind execution client with the ETC Cooperative's Ethereum Classic plugin";
    homepage = "https://github.com/ETCCooperative/nethermind-etc-plugin";
    license = [
      licenses.lgpl3Plus # Nethermind
      licenses.gpl3Only # ETC plugin
    ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "nethermind-etc";
  };
}
